import Foundation
@testable import RainCore
@testable import RainPrivy
import Testing

@Suite("Privy Session Coordinator Tests")
struct PrivySessionCoordinatorTests {

  /// Controllable seam double: settable current state, continuation-backed stream, and a
  /// scripted refresh outcome.
  private final class FakeAuthSource: PrivyAuthSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PrivySessionState
    private var continuations: [AsyncStream<PrivySessionState>.Continuation] = []

    var refreshError: Error?
    private(set) var refreshCalls = 0

    init(_ initial: PrivySessionState) {
      current = initial
    }

    var sessionStateStream: AsyncStream<PrivySessionState> {
      AsyncStream { continuation in
        lock.withLock { continuations.append(continuation) }
      }
    }

    /// True once the coordinator's consuming task has actually subscribed.
    var hasSubscribers: Bool {
      lock.withLock { !continuations.isEmpty }
    }

    func currentSessionState() -> PrivySessionState {
      lock.withLock { current }
    }

    func refreshUser() async throws {
      lock.withLock { refreshCalls += 1 }
      if let refreshError { throw refreshError }
    }

    func send(_ state: PrivySessionState) {
      let targets: [AsyncStream<PrivySessionState>.Continuation] = lock.withLock {
        current = state
        return continuations
      }
      targets.forEach { $0.yield(state) }
    }
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
  }

  private final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var delays: [TimeInterval] { lock.withLock { recorded } }
    func record(_ delay: TimeInterval) { lock.withLock { recorded.append(delay) } }
  }

  private func makeCoordinator(
    auth: FakeAuthSource,
    policy: PrivySessionPolicy = PrivySessionPolicy(),
    onSessionExpired: (@Sendable () -> Void)? = nil,
    delayRecorder: DelayRecorder = DelayRecorder()
  ) -> PrivySessionCoordinator {
    PrivySessionCoordinator(
      auth: auth,
      policy: policy,
      onSessionExpired: onSessionExpired,
      sleep: { delayRecorder.record($0) }
    )
  }

  private func privyAuthError() -> Error {
    // The mapping-independent auth signal the coordinator recognizes.
    RainError.tokenExpired
  }

  // MARK: - Auth-state guard

  @Test("unauthenticated state throws tokenExpired without running the call")
  func unauthenticatedGuard() async throws {
    let auth = FakeAuthSource(.unauthenticated)
    let coordinator = makeCoordinator(auth: auth)
    let runs = Counter()

    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { runs.increment() }
    }
    #expect(runs.value == 0)
  }

  @Test("never-logged-in user gets tokenExpired but the expiry hook stays silent")
  func neverLoggedInSilent() async throws {
    let auth = FakeAuthSource(.unauthenticated)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })

    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { }
    }
    #expect(hookCalls.value == 0)
  }

  @Test("call during credential restore waits for loading to resolve instead of expiring")
  func waitsOutRestore() async throws {
    let auth = FakeAuthSource(.loading)
    let hookCalls = Counter()
    let checks = Counter()
    // The injected sleep doubles as the restore trigger.
    let coordinator = PrivySessionCoordinator(
      auth: auth,
      onSessionExpired: { hookCalls.increment() },
      sleep: { _ in
        checks.increment()
        if checks.value == 3 { auth.send(.active) }
      }
    )

    let result = try await coordinator.executeRead { "ok" }

    #expect(result == "ok")
    #expect(hookCalls.value == 0)
  }

  // MARK: - Auth-failure surfacing

  @Test("auth failure surfaces tokenExpired and fires the hook once")
  func authFailureFiresHookOnce() async throws {
    let auth = FakeAuthSource(.active)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })

    for _ in 0..<2 {
      await #expect(throws: RainError.tokenExpired) {
        _ = try await coordinator.executeRead { throw self.privyAuthError() }
      }
    }
    #expect(hookCalls.value == 1)
  }

  @Test("auth failure on a write is never retried")
  func writeAuthFailureNotRetried() async throws {
    let auth = FakeAuthSource(.active)
    let attempts = Counter()
    let coordinator = makeCoordinator(auth: auth)

    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeWrite {
        attempts.increment()
        throw self.privyAuthError()
      }
    }
    #expect(attempts.value == 1)
  }

  // MARK: - Transient backoff

  @Test("transient network failure on a read retries with exponential backoff then succeeds")
  func transientBackoffThenSuccess() async throws {
    let auth = FakeAuthSource(.active)
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(auth: auth, delayRecorder: delays)
    let attempts = Counter()

    let result = try await coordinator.executeRead { () -> String in
      attempts.increment()
      if attempts.value <= 2 { throw URLError(.networkConnectionLost) }
      return "ok"
    }

    #expect(result == "ok")
    #expect(delays.delays == [0.5, 1.0])
  }

  @Test("transient failures beyond maxTransientRetries surface the original error")
  func transientExhausted() async throws {
    let auth = FakeAuthSource(.active)
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(
      auth: auth,
      policy: PrivySessionPolicy(maxTransientRetries: 2),
      delayRecorder: delays
    )
    let attempts = Counter()

    await #expect(throws: URLError.self) {
      _ = try await coordinator.executeRead { () -> String in
        attempts.increment()
        throw URLError(.timedOut)
      }
    }
    #expect(attempts.value == 3)
    #expect(delays.delays.count == 2)
  }

  @Test("backoff delays are capped at maxRetryDelay")
  func backoffCapped() async throws {
    let auth = FakeAuthSource(.active)
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(
      auth: auth,
      policy: PrivySessionPolicy(maxTransientRetries: 4, initialRetryDelay: 0.5, maxRetryDelay: 1.0),
      delayRecorder: delays
    )

    await #expect(throws: URLError.self) {
      _ = try await coordinator.executeRead { () -> String in throw URLError(.timedOut) }
    }
    #expect(delays.delays == [0.5, 1.0, 1.0, 1.0])
  }

  @Test("transient failure on a write is not retried")
  func writeNotRetriedOnTransient() async throws {
    let auth = FakeAuthSource(.active)
    let attempts = Counter()
    let coordinator = makeCoordinator(auth: auth)

    await #expect(throws: URLError.self) {
      _ = try await coordinator.executeWrite { () -> String in
        attempts.increment()
        throw URLError(.timedOut)
      }
    }
    #expect(attempts.value == 1)
  }

  @Test("non-transient non-auth errors are not retried on reads")
  func nonTransientNotRetried() async throws {
    let auth = FakeAuthSource(.active)
    let attempts = Counter()
    let coordinator = makeCoordinator(auth: auth)
    struct Odd: Error {}

    await #expect(throws: Odd.self) {
      _ = try await coordinator.executeRead { () -> String in
        attempts.increment()
        throw Odd()
      }
    }
    #expect(attempts.value == 1)
  }

  // MARK: - Manual refresh

  @Test("refreshNow refreshes through the Privy user")
  func manualRefresh() async throws {
    let auth = FakeAuthSource(.active)
    let coordinator = makeCoordinator(auth: auth)

    try await coordinator.refreshNow()

    #expect(auth.refreshCalls == 1)
  }

  @Test("refreshNow surfaces tokenExpired and fires the hook when the refresh fails")
  func manualRefreshFailure() async throws {
    let auth = FakeAuthSource(.active)
    auth.refreshError = URLError(.userAuthenticationRequired)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })

    await #expect(throws: RainError.tokenExpired) {
      try await coordinator.refreshNow()
    }
    #expect(hookCalls.value == 1)
  }

  // MARK: - Session state

  @Test("currentState reflects the auth source")
  func currentStateDerivation() async throws {
    let auth = FakeAuthSource(.loading)
    let coordinator = makeCoordinator(auth: auth)

    #expect(coordinator.currentState() == .loading)
    auth.send(.active)
    #expect(coordinator.currentState() == .active)
    auth.send(.unverified)
    #expect(coordinator.currentState() == .unverified)
    auth.send(.unauthenticated)
    #expect(coordinator.currentState() == .unauthenticated)
  }

  // MARK: - Passive watcher

  @Test("watcher fires the hook and death callbacks once when an active session dies")
  func watcherFiresOnce() async throws {
    let auth = FakeAuthSource(.active)
    let hookCalls = Counter()
    let evictions = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })
    coordinator.onSessionDeath { evictions.increment() }
    coordinator.startMonitoring()
    for _ in 0..<200 where !auth.hasSubscribers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    auth.send(.unauthenticated)
    for _ in 0..<200 where hookCalls.value == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.value == 1)
    #expect(evictions.value == 1)

    // Repeated emissions must not re-fire for the same death.
    auth.send(.loading)
    auth.send(.unauthenticated)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(hookCalls.value == 1)
  }

  @Test("watcher fires when an active session dies through a loading transition")
  func watcherFiresThroughLoading() async throws {
    let auth = FakeAuthSource(.active)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })
    coordinator.startMonitoring()
    for _ in 0..<200 where !auth.hasSubscribers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    auth.send(.loading)
    auth.send(.unauthenticated)
    for _ in 0..<200 where hookCalls.value == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.value == 1)
  }

  @Test("hook re-arms after a re-login and fires again for a second death")
  func hookReArmsAfterReLogin() async throws {
    let auth = FakeAuthSource(.active)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })
    coordinator.startMonitoring()
    for _ in 0..<200 where !auth.hasSubscribers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    auth.send(.unauthenticated)
    for _ in 0..<200 where hookCalls.value == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.value == 1)

    // Re-login re-arms; a second death must fire again.
    auth.send(.active)
    auth.send(.unauthenticated)
    for _ in 0..<200 where hookCalls.value == 1 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.value == 2)
  }

  @Test("watcher stays silent for a user who never logged in")
  func watcherSilentWhenNeverLoggedIn() async throws {
    let auth = FakeAuthSource(.loading)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })
    coordinator.startMonitoring()
    for _ in 0..<200 where !auth.hasSubscribers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    auth.send(.unauthenticated)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(hookCalls.value == 0)
  }

  @Test("sessionStates re-broadcasts auth transitions to subscribers")
  func sessionStatesPublisher() async throws {
    let auth = FakeAuthSource(.active)
    let coordinator = makeCoordinator(auth: auth)

    let states = LockedStates()
    let cancellable = coordinator.sessionStates.sink { states.append($0) }
    defer { cancellable.cancel() }

    // The coordinator's consuming task subscribes asynchronously; emit only once it has.
    for _ in 0..<200 where !auth.hasSubscribers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    auth.send(.unauthenticated)
    for _ in 0..<200 where states.value.last != .unauthenticated {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(states.value.first == .active)
    #expect(states.value.last == .unauthenticated)
  }

  @Test("a closed coordinator never fires its hook")
  func closedCoordinatorSilent() async throws {
    let auth = FakeAuthSource(.active)
    let hookCalls = Counter()
    let coordinator = makeCoordinator(auth: auth, onSessionExpired: { hookCalls.increment() })
    coordinator.startMonitoring()
    for _ in 0..<200 where !auth.hasSubscribers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    coordinator.stopMonitoring()
    auth.send(.unauthenticated)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(hookCalls.value == 0)
  }
}

private final class LockedStates: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [PrivySessionState] = []
  var value: [PrivySessionState] { lock.withLock { stored } }
  func append(_ state: PrivySessionState) { lock.withLock { stored.append(state) } }
}
