import Foundation
@testable import PortalSwift
@testable import RainCore
@testable import RainPortal
import Testing

@Suite("Portal Session Coordinator Tests")
struct PortalSessionCoordinatorTests {

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    @discardableResult func increment() -> Int { lock.withLock { stored += 1; return stored } }
  }

  private final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var delays: [TimeInterval] { lock.withLock { recorded } }
    func record(_ delay: TimeInterval) { lock.withLock { recorded.append(delay) } }
  }

  private final class InstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: [String] = []
    var failWith: Error?
    var tokens: [String] { lock.withLock { installed } }
    func install(_ token: String) throws {
      if let failWith { throw failWith }
      lock.withLock { installed.append(token) }
    }
  }

  private func makeCoordinator(
    policy: PortalSessionPolicy = PortalSessionPolicy(),
    onSessionTokenNeeded: (@Sendable () async throws -> String?)? = nil,
    onSessionExpired: (@Sendable () -> Void)? = nil,
    installer: InstallRecorder = InstallRecorder(),
    delayRecorder: DelayRecorder = DelayRecorder()
  ) -> PortalSessionCoordinator {
    PortalSessionCoordinator(
      policy: policy,
      onSessionTokenNeeded: onSessionTokenNeeded,
      onSessionExpired: onSessionExpired,
      installToken: { try installer.install($0) },
      sleep: { delayRecorder.record($0) }
    )
  }

  private let unauthorized: Error = PortalRequestsError.unauthorized
  private func serverError() -> Error {
    PortalRequestsError.internalServerError("503 - upstream", url: "https://api.portalhq.io/x")
  }
  private func invalidApiKey() -> Error {
    var vendorError = PortalError()
    vendorError.id = "\(PortalErrorCodes.INVALID_API_KEY.rawValue)"
    vendorError.message = "invalid api key"
    return PortalMpcError(vendorError)
  }

  // MARK: - State

  @Test("starts unknown and becomes active after a successful call")
  func stateTransitions() async throws {
    let coordinator = makeCoordinator()
    #expect(coordinator.currentState() == .unknown)
    _ = try await coordinator.executeRead { "ok" }
    #expect(coordinator.currentState() == .active)
  }

  // MARK: - Auth failure without refresh

  @Test("auth failure without a refresh hook surfaces tokenExpired and fires the hook once")
  func terminalAuthFailure() async throws {
    let hookCalls = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() })

    for _ in 0..<2 {
      await #expect(throws: RainError.tokenExpired) {
        _ = try await coordinator.executeRead { throw self.unauthorized }
      }
    }
    #expect(hookCalls.value == 1)
    #expect(coordinator.currentState() == .expired)
  }

  @Test("MPC invalid-api-key is an auth failure too")
  func mpcAuthFailure() async throws {
    let hookCalls = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() })
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeWrite { throw self.invalidApiKey() }
    }
    #expect(hookCalls.value == 1)
  }

  @Test("once expired, calls fail fast without running the block")
  func failFastWhenExpired() async throws {
    let coordinator = makeCoordinator()
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    let runs = Counter()
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { runs.increment() }
    }
    #expect(runs.value == 0)
  }

  @Test("autoRefresh off never consults the re-mint hook")
  func autoRefreshOff() async throws {
    let mints = Counter()
    let coordinator = makeCoordinator(
      policy: PortalSessionPolicy(autoRefresh: false),
      onSessionTokenNeeded: { mints.increment(); return "new" }
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(mints.value == 0)
  }

  // MARK: - Refresh (re-mint + rebuild)

  @Test("auth failure re-mints, installs the token and retries the read once")
  func refreshAndRetryRead() async throws {
    let installer = InstallRecorder()
    let hookCalls = Counter()
    let attempts = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { "new-token" },
      onSessionExpired: { hookCalls.increment() },
      installer: installer
    )

    let result = try await coordinator.executeRead {
      if attempts.increment() == 1 { throw self.unauthorized }
      return "ok"
    }

    #expect(result == "ok")
    #expect(attempts.value == 2)
    #expect(installer.tokens == ["new-token"])
    #expect(hookCalls.value == 0)
    #expect(coordinator.currentState() == .active)
  }

  @Test("a write rejected before execution is retried once after the token swap")
  func refreshAndRetryWrite() async throws {
    let attempts = Counter()
    let coordinator = makeCoordinator(onSessionTokenNeeded: { "new-token" })
    let hash = try await coordinator.executeWrite {
      if attempts.increment() == 1 { throw self.invalidApiKey() }
      return "0xhash"
    }
    #expect(hash == "0xhash")
    #expect(attempts.value == 2)
  }

  @Test("auth failure after a refresh is terminal — no second re-mint")
  func noSecondRefresh() async throws {
    let mints = Counter()
    let hookCalls = Counter()
    let attempts = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { mints.increment(); return "still-bad" },
      onSessionExpired: { hookCalls.increment() }
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { attempts.increment(); throw self.unauthorized }
    }
    #expect(attempts.value == 2)
    #expect(mints.value == 1)
    #expect(hookCalls.value == 1)
    #expect(coordinator.currentState() == .expired)
  }

  @Test("host declining the re-mint surfaces tokenExpired and fires the hook")
  func hostDeclines() async throws {
    let installer = InstallRecorder()
    let hookCalls = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { nil },
      onSessionExpired: { hookCalls.increment() },
      installer: installer
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(installer.tokens.isEmpty)
    #expect(hookCalls.value == 1)
  }

  @Test("re-mint hook throwing surfaces tokenExpired, not the hook's error")
  func mintThrows() async throws {
    struct BackendDown: Error {}
    let hookCalls = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { throw BackendDown() },
      onSessionExpired: { hookCalls.increment() }
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(hookCalls.value == 1)
  }

  @Test("client rebuild failing surfaces tokenExpired and fires the hook")
  func rebuildFails() async throws {
    struct RebuildFailed: Error {}
    let installer = InstallRecorder()
    installer.failWith = RebuildFailed()
    let hookCalls = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { "new-token" },
      onSessionExpired: { hookCalls.increment() },
      installer: installer
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(hookCalls.value == 1)
  }

  @Test("an expired session is re-minted before the next call instead of failing fast")
  func preCallGuardRefreshes() async throws {
    final class MintBox: @unchecked Sendable { var token: String? }
    let box = MintBox()
    let installer = InstallRecorder()
    let hookCalls = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { box.token },
      onSessionExpired: { hookCalls.increment() },
      installer: installer
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(coordinator.currentState() == .expired)

    box.token = "fresh"
    let runs = Counter()
    let result = try await coordinator.executeRead { runs.increment(); return "ok" }

    #expect(result == "ok")
    #expect(runs.value == 1)
    #expect(installer.tokens == ["fresh"])
    #expect(hookCalls.value == 1)
  }

  @Test("the expiry hook re-arms after a successful refresh")
  func hookRearms() async throws {
    final class Queue: @unchecked Sendable {
      private let lock = NSLock()
      private var items: [String]
      init(_ items: [String]) { self.items = items }
      func next() -> String? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
    }
    let tokens = Queue(["second", "third"])
    let hookCalls = Counter()
    let coordinator = makeCoordinator(
      onSessionTokenNeeded: { tokens.next() },
      onSessionExpired: { hookCalls.increment() }
    )
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(hookCalls.value == 1)
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(hookCalls.value == 2)
  }

  @Test("concurrent callers rejected on the same token share one re-mint")
  func singleFlightRefresh() async throws {
    let mints = Counter()
    let installer = InstallRecorder()
    let attempts = Counter()
    let coordinator = PortalSessionCoordinator(
      onSessionTokenNeeded: {
        mints.increment()
        try await Task.sleep(nanoseconds: 50_000_000)
        return "new-token"
      },
      installToken: { try installer.install($0) },
      sleep: { _ in }
    )
    @Sendable func block() async throws -> String {
      if attempts.increment() <= 2 { throw self.unauthorized }
      return "ok"
    }

    async let a = coordinator.executeRead { try await block() }
    async let b = coordinator.executeRead { try await block() }
    let (ra, rb) = try await (a, b)

    #expect(ra == "ok")
    #expect(rb == "ok")
    #expect(mints.value == 1)
    #expect(installer.tokens == ["new-token"])
  }

  @Test("a token swapped while a call was in flight makes the call retry instead of expiring")
  func swapDuringInFlightCall() async throws {
    let hookCalls = Counter()
    let attempts = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() })

    let result = try await coordinator.executeRead {
      if attempts.increment() == 1 {
        // The host installs a new token out of band while this attempt is in flight, then the
        // old token's rejection arrives.
        try await coordinator.installNow("out-of-band")
        throw self.unauthorized
      }
      return "ok"
    }

    #expect(result == "ok")
    #expect(attempts.value == 2)
    #expect(hookCalls.value == 0)
    #expect(coordinator.currentState() == .active)
  }

  @Test("callers in flight during a failed mint share the failure instead of re-minting")
  func sharedFailedMint() async throws {
    let mints = Counter()
    let hookCalls = Counter()
    let coordinator = PortalSessionCoordinator(
      onSessionTokenNeeded: {
        mints.increment()
        try await Task.sleep(nanoseconds: 50_000_000)
        return nil
      },
      onSessionExpired: { hookCalls.increment() },
      sleep: { _ in }
    )
    // b's first attempt lands while a's mint is in flight and b's rejection arrives after it
    // failed — b must not ask the host again.
    async let a: Void = {
      await #expect(throws: RainError.tokenExpired) {
        _ = try await coordinator.executeRead { throw self.unauthorized }
      }
    }()
    async let b: Void = {
      try? await Task.sleep(nanoseconds: 10_000_000)
      await #expect(throws: RainError.tokenExpired) {
        _ = try await coordinator.executeRead {
          try await Task.sleep(nanoseconds: 60_000_000)
          throw self.unauthorized
        }
      }
    }()
    _ = await (a, b)

    #expect(mints.value == 1)
    #expect(hookCalls.value == 1)
  }

  @Test("installNow during an in-flight refresh installs the host's token, not the minted one")
  func installDuringRefresh() async throws {
    let installer = InstallRecorder()
    let coordinator = PortalSessionCoordinator(
      onSessionTokenNeeded: {
        try await Task.sleep(nanoseconds: 50_000_000)
        return "minted"
      },
      installToken: { try installer.install($0) },
      sleep: { _ in }
    )
    async let refresh: Void = coordinator.refreshNow()
    try await Task.sleep(nanoseconds: 10_000_000)
    try await coordinator.installNow("host")
    try await refresh

    #expect(installer.tokens == ["minted", "host"])
    #expect(coordinator.currentState() == .active)
  }

  @Test("a transient failure wrapped in providerError is retried")
  func providerErrorWrappedTransient() async throws {
    let attempts = Counter()
    let coordinator = makeCoordinator()
    let result = try await coordinator.executeRead {
      if attempts.increment() == 1 {
        throw RainError.providerError(underlying: URLError(.timedOut))
      }
      return "ok"
    }
    #expect(result == "ok")
    #expect(attempts.value == 2)
  }

  @Test("refreshNow re-mints and re-arms without a failing call")
  func refreshNow() async throws {
    let installer = InstallRecorder()
    let coordinator = makeCoordinator(onSessionTokenNeeded: { "manual" }, installer: installer)
    try await coordinator.refreshNow()
    #expect(installer.tokens == ["manual"])
    #expect(coordinator.currentState() == .active)
  }

  @Test("refreshNow without a re-mint hook throws tokenExpired")
  func refreshNowWithoutHook() async throws {
    let hookCalls = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() })
    await #expect(throws: RainError.tokenExpired) {
      try await coordinator.refreshNow()
    }
    #expect(hookCalls.value == 1)
  }

  @Test("installNow swaps a host-minted token and revives an expired session")
  func installNow() async throws {
    let installer = InstallRecorder()
    let coordinator = makeCoordinator(installer: installer)
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    try await coordinator.installNow("host-minted")
    let result = try await coordinator.executeRead { "ok" }
    #expect(installer.tokens == ["host-minted"])
    #expect(result == "ok")
    #expect(coordinator.currentState() == .active)
  }

  @Test("installNow failing to rebuild keeps the live session and never fires the hook")
  func installNowFailureKeepsLiveSession() async throws {
    let installer = InstallRecorder()
    let hookCalls = Counter()
    let attempts = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() }, installer: installer)
    _ = try await coordinator.executeRead { "ok" }

    installer.failWith = NSError(domain: "portal", code: 7)
    do {
      try await coordinator.installNow("garbage")
      Issue.record("installNow should have thrown")
    } catch let error as RainError {
      guard case .invalidConfig = error else {
        Issue.record("expected invalidConfig, got \(error)")
        return
      }
    }

    #expect(coordinator.currentState() == .active)
    #expect(hookCalls.value == 0)
    #expect(installer.tokens.isEmpty)
    // The old client is still installed, so calls keep running against it.
    let result = try await coordinator.executeRead { attempts.increment(); return "still ok" }
    #expect(result == "still ok")
    #expect(attempts.value == 1)
  }

  @Test("installNow failing while expired stays expired without re-firing the hook")
  func installNowFailureWhileExpired() async throws {
    let installer = InstallRecorder()
    let hookCalls = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() }, installer: installer)
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    installer.failWith = NSError(domain: "portal", code: 7)
    await #expect(throws: RainError.self) {
      try await coordinator.installNow("garbage")
    }
    #expect(coordinator.currentState() == .expired)
    #expect(hookCalls.value == 1)
  }

  @Test("installNow rejects a blank token")
  func installNowBlank() async throws {
    let coordinator = makeCoordinator()
    await #expect(throws: RainError.invalidConfig(details: "Portal session token must not be empty")) {
      try await coordinator.installNow("  ")
    }
  }

  // MARK: - Transient backoff

  @Test("reads retry transient failures with exponential backoff")
  func transientBackoff() async throws {
    let delays = DelayRecorder()
    let attempts = Counter()
    let coordinator = makeCoordinator(
      policy: PortalSessionPolicy(maxTransientRetries: 3, initialRetryDelay: 0.1, maxRetryDelay: 0.25),
      delayRecorder: delays
    )
    let result = try await coordinator.executeRead {
      switch attempts.increment() {
      case 1: throw self.serverError()
      case 2: throw PortalRequestsError.clientError("429 - slow down", url: "https://api.portalhq.io/x")
      case 3: throw URLError(.networkConnectionLost)
      default: return "ok"
      }
    }
    #expect(result == "ok")
    #expect(attempts.value == 4)
    #expect(delays.delays == [0.1, 0.2, 0.25])
  }

  @Test("reads give up after maxTransientRetries and rethrow the last failure")
  func transientGivesUp() async throws {
    let attempts = Counter()
    let coordinator = makeCoordinator(policy: PortalSessionPolicy(maxTransientRetries: 1))
    await #expect(throws: PortalRequestsError.self) {
      _ = try await coordinator.executeRead { attempts.increment(); throw self.serverError() }
    }
    #expect(attempts.value == 2)
  }

  @Test("writes never retry transient failures")
  func writesNoTransientRetry() async throws {
    let delays = DelayRecorder()
    let attempts = Counter()
    let coordinator = makeCoordinator(delayRecorder: delays)
    await #expect(throws: PortalRequestsError.self) {
      _ = try await coordinator.executeWrite { attempts.increment(); throw self.serverError() }
    }
    #expect(attempts.value == 1)
    #expect(delays.delays.isEmpty)
  }

  @Test("non-transient non-auth failures are rethrown untouched")
  func nonTransientPassthrough() async throws {
    let attempts = Counter()
    let coordinator = makeCoordinator()
    await #expect(throws: PortalRequestsError.self) {
      _ = try await coordinator.executeRead {
        attempts.increment()
        throw PortalRequestsError.clientError("400 - bad request", url: "https://api.portalhq.io/x")
      }
    }
    #expect(attempts.value == 1)
  }

  // MARK: - Lifecycle

  @Test("a stopped coordinator never fires the hook or death callbacks")
  func stoppedSilent() async throws {
    let hookCalls = Counter()
    let deathCalls = Counter()
    let coordinator = makeCoordinator(onSessionExpired: { hookCalls.increment() })
    coordinator.onSessionDeath { deathCalls.increment() }
    coordinator.stop()
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(hookCalls.value == 0)
    #expect(deathCalls.value == 0)
  }

  @Test("death callbacks run before the host hook")
  func deathCallbackOrder() async throws {
    final class Order: @unchecked Sendable {
      private let lock = NSLock()
      private var items: [String] = []
      var value: [String] { lock.withLock { items } }
      func add(_ s: String) { lock.withLock { items.append(s) } }
    }
    let order = Order()
    let coordinator = makeCoordinator(onSessionExpired: { order.add("hook") })
    coordinator.onSessionDeath { order.add("evict") }
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(order.value == ["evict", "hook"])
  }

  @Test("sessionState publishes the expired transition")
  func publishesState() async throws {
    final class Seen: @unchecked Sendable {
      private let lock = NSLock()
      private var items: [PortalSessionState] = []
      var value: [PortalSessionState] { lock.withLock { items } }
      func add(_ s: PortalSessionState) { lock.withLock { items.append(s) } }
    }
    let seen = Seen()
    let coordinator = makeCoordinator()
    let cancellable = coordinator.sessionStates.sink { seen.add($0) }
    defer { cancellable.cancel() }
    _ = try await coordinator.executeRead { "ok" }
    await #expect(throws: RainError.tokenExpired) {
      _ = try await coordinator.executeRead { throw self.unauthorized }
    }
    #expect(seen.value == [.unknown, .active, .expired])
  }
}
