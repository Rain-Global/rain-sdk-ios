import Combine
import Foundation
@testable import RainCore
@testable import RainTurnkey
import Testing
import TurnkeyHttp
import TurnkeySwift
import TurnkeyTypes

@Suite("TurnkeySessionCoordinator")
struct TurnkeySessionCoordinatorTests {
  /// Turnkey mapping now registers via TurnkeyErrorMapping (like Portal/Privy);
  /// tests exercising RainError.from with Turnkey errors must ensure it ran.
  init() { TurnkeyErrorMapping.registerOnce() }


  private final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { recorded } }

    func record(_ delay: TimeInterval) {
      lock.withLock { recorded.append(delay) }
    }
  }

  private func makeCoordinator(
    turnkey: MockTurnkey,
    policy: TurnkeySessionPolicy = TurnkeySessionPolicy(),
    onSessionExpired: (@Sendable () -> Void)? = nil,
    delayRecorder: DelayRecorder = DelayRecorder(),
    now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
  ) -> TurnkeySessionCoordinator {
    TurnkeySessionCoordinator(
      turnkey: turnkey,
      policy: policy,
      onSessionExpired: onSessionExpired,
      now: now,
      sleep: { delayRecorder.record($0) }
    )
  }

  private func activitiesBody(organizationId: String) -> TGetActivitiesBody {
    TGetActivitiesBody(
      organizationId: organizationId,
      filterByType: [],
      paginationOptions: nil
    )
  }

  private func readActivities(
    _ coordinator: TurnkeySessionCoordinator
  ) async throws -> TGetActivitiesResponse {
    try await coordinator.executeRead { session, client in
      try await client.getActivities(self.activitiesBody(organizationId: session.organizationId))
    }
  }

  // MARK: - Expiry checks

  @Test("missing session throws tokenExpired without touching the client")
  func missingSession() async throws {
    let turnkey = MockTurnkey(session: nil)
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let coordinator = makeCoordinator(turnkey: turnkey)

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(client.getActivitiesCalls.isEmpty)
  }

  @Test("expired session throws tokenExpired without a server call when autoRefresh is off")
  func expiredSessionNoAutoRefresh() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.expiredSession())
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      policy: TurnkeySessionPolicy(autoRefresh: false)
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(client.getActivitiesCalls.isEmpty)
    #expect(turnkey.refreshSessionCallCount == 0)
  }

  @Test("near-expiry session inside the buffer proceeds without refresh when autoRefresh is off")
  func nearExpiryNoAutoRefresh() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.nearExpirySession(remainingSeconds: 10))
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      policy: TurnkeySessionPolicy(autoRefresh: false)
    )

    _ = try await readActivities(coordinator)

    #expect(client.getActivitiesCalls.count == 1)
    #expect(turnkey.refreshSessionCallCount == 0)
  }

  // MARK: - Proactive refresh

  @Test("near-expiry session is refreshed proactively before the call")
  func proactiveRefresh() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.nearExpirySession(remainingSeconds: 10))
    turnkey.onRefreshSession = { turnkey.session = MockTurnkey.defaultSession() }
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let coordinator = makeCoordinator(turnkey: turnkey)

    _ = try await readActivities(coordinator)

    #expect(turnkey.refreshSessionCallCount == 1)
    #expect(client.getActivitiesCalls.count == 1)
  }

  @Test("expired session is refreshed and the call proceeds")
  func expiredSessionRefreshes() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.expiredSession())
    turnkey.onRefreshSession = { turnkey.session = MockTurnkey.defaultSession() }
    let coordinator = makeCoordinator(turnkey: turnkey)

    _ = try await readActivities(coordinator)

    #expect(turnkey.refreshSessionCallCount == 1)
  }

  @Test("refresh TTL from the policy is passed through to Turnkey")
  func refreshTTLPassthrough() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.expiredSession())
    turnkey.onRefreshSession = { turnkey.session = MockTurnkey.defaultSession() }
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      policy: TurnkeySessionPolicy(refreshExpirationSeconds: 1800)
    )

    _ = try await readActivities(coordinator)

    #expect(turnkey.refreshSessionCalls == ["1800"])
  }

  @Test("failed refresh surfaces tokenExpired and fires the expiry hook once")
  func failedRefreshFiresHookOnce() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.expiredSession())
    turnkey.refreshSessionError = TurnkeySwiftError.failedToRefreshSession(
      underlying: NSError(domain: "test", code: 1)
    )
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(hookCalls.delays.count == 1)
  }

  @Test("proactive refresh failing on a network error proceeds on the still-valid session")
  func proactiveRefreshNetworkFailureProceeds() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.nearExpirySession(remainingSeconds: 10))
    turnkey.refreshSessionError = TurnkeySwiftError.failedToRefreshSession(
      underlying: TurnkeyRequestError.network(URLError(.notConnectedToInternet))
    )
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )

    _ = try await readActivities(coordinator)

    #expect(turnkey.refreshSessionCallCount == 1)
    #expect(client.getActivitiesCalls.count == 1)
    #expect(hookCalls.delays.isEmpty)
  }

  @Test("proactive refresh rejected by Turnkey expires the near-expiry session")
  func proactiveRefreshAuthFailureExpires() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.nearExpirySession(remainingSeconds: 10))
    turnkey.refreshSessionError = TurnkeySwiftError.failedToRefreshSession(
      underlying: TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    )
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(client.getActivitiesCalls.isEmpty)
    #expect(hookCalls.delays.count == 1)
  }

  // MARK: - Refresh-on-401 retry

  @Test("401 mid-call refreshes the session and retries once")
  func refreshOn401() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    turnkey.onRefreshSession = {
      turnkey.session = MockTurnkey.defaultSession()
      client.getActivitiesError = nil
    }
    let coordinator = makeCoordinator(turnkey: turnkey)

    _ = try await readActivities(coordinator)

    #expect(turnkey.refreshSessionCallCount == 1)
    #expect(client.getActivitiesCalls.count == 2)
  }

  @Test("persistent 401 surfaces tokenExpired after one refresh-and-retry")
  func persistent401() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(turnkey.refreshSessionCallCount == 1)
    #expect(client.getActivitiesCalls.count == 2)
    #expect(hookCalls.delays.count == 1)
  }

  @Test("401 on a write also refreshes and retries once")
  func writeRefreshOn401() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    turnkey.onRefreshSession = { client.getActivitiesError = nil }
    let coordinator = makeCoordinator(turnkey: turnkey)

    _ = try await coordinator.executeWrite { session, client in
      try await client.getActivities(self.activitiesBody(organizationId: session.organizationId))
    }

    #expect(turnkey.refreshSessionCallCount == 1)
    #expect(client.getActivitiesCalls.count == 2)
  }

  @Test("401 with autoRefresh off surfaces tokenExpired without a refresh attempt")
  func noRefreshWhenAutoRefreshOff() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      policy: TurnkeySessionPolicy(autoRefresh: false)
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(turnkey.refreshSessionCallCount == 0)
    #expect(client.getActivitiesCalls.count == 1)
  }

  // MARK: - Transient backoff

  @Test("transient 500 on a read retries with exponential backoff and then succeeds")
  func transientBackoffThenSuccess() async throws {
    let turnkey = MockTurnkey()
    let inner = turnkey.turnkeyClient as! MockTurnkeyClient
    let flaky = FlakyTurnkeyClient(
      wrapping: inner,
      failures: 2,
      error: TurnkeyRequestError.apiError(statusCode: 500, payload: nil)
    )
    turnkey.turnkeyClient = flaky
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(turnkey: turnkey, delayRecorder: delays)

    _ = try await readActivities(coordinator)

    #expect(delays.delays == [0.5, 1.0])
    #expect(turnkey.refreshSessionCallCount == 0)
    #expect(inner.getActivitiesCalls.count == 1)
  }

  @Test("transient failures beyond maxTransientRetries surface the original error")
  func transientRetriesExhausted() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = URLError(.networkConnectionLost)
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      policy: TurnkeySessionPolicy(maxTransientRetries: 2),
      delayRecorder: delays
    )

    await #expect(throws: URLError.self) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(client.getActivitiesCalls.count == 3)
    #expect(delays.delays.count == 2)
  }

  @Test("backoff delays are capped at maxRetryDelay")
  func backoffCapped() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = URLError(.timedOut)
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      policy: TurnkeySessionPolicy(
        maxTransientRetries: 4,
        initialRetryDelay: 0.5,
        maxRetryDelay: 1.0
      ),
      delayRecorder: delays
    )

    await #expect(throws: URLError.self) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(delays.delays == [0.5, 1.0, 1.0, 1.0])
  }

  @Test("transient failure on a write is not retried")
  func writeNotRetriedOnTransient() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = URLError(.timedOut)
    let coordinator = makeCoordinator(turnkey: turnkey)

    await #expect(throws: URLError.self) {
      _ = try await coordinator.executeWrite { session, client in
        try await client.getActivities(self.activitiesBody(organizationId: session.organizationId))
      }
    }
    #expect(client.getActivitiesCalls.count == 1)
  }

  @Test("non-transient non-auth errors are not retried on reads")
  func nonTransientNotRetried() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = TurnkeyRequestError.apiError(statusCode: 400, payload: nil)
    let coordinator = makeCoordinator(turnkey: turnkey)

    await #expect(throws: TurnkeyRequestError.self) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(client.getActivitiesCalls.count == 1)
    #expect(turnkey.refreshSessionCallCount == 0)
  }

  // MARK: - Manual refresh

  @Test("refreshNow refreshes through Turnkey")
  func manualRefresh() async throws {
    let turnkey = MockTurnkey()
    let coordinator = makeCoordinator(turnkey: turnkey)

    try await coordinator.refreshNow()

    #expect(turnkey.refreshSessionCallCount == 1)
  }

  @Test("refreshNow surfaces tokenExpired when the refresh fails")
  func manualRefreshFailure() async throws {
    let turnkey = MockTurnkey()
    turnkey.refreshSessionError = TurnkeySwiftError.invalidSession
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )

    await #expect(throws: RainError.tokenExpired) {
      try await coordinator.refreshNow()
    }
    #expect(hookCalls.delays.count == 1)
  }

  // MARK: - Session state

  @Test("currentState reflects auth state and expiry")
  func currentStateDerivation() async throws {
    let turnkey = MockTurnkey()
    let coordinator = makeCoordinator(turnkey: turnkey)

    guard case .active = coordinator.currentState() else {
      Issue.record("expected active")
      return
    }

    turnkey.session = MockTurnkey.expiredSession()
    #expect(coordinator.currentState() == .expired)

    turnkey.session = nil
    turnkey.authState = .unAuthenticated
    #expect(coordinator.currentState() == .unauthenticated)

    turnkey.authState = .loading
    #expect(coordinator.currentState() == .loading)
  }

  @Test("sessionState emits unauthenticated when Turnkey clears the session")
  func sessionStateEmitsOnLogout() async throws {
    let turnkey = MockTurnkey()
    let coordinator = makeCoordinator(turnkey: turnkey)

    let states = LockedBox<[TurnkeySessionState]>([])
    let cancellable = coordinator.sessionStates.sink { state in
      states.mutate { $0.append(state) }
    }
    defer { cancellable.cancel() }

    // Delivery is serialized onto a background queue, so the initial value arrives async.
    for _ in 0..<100 where states.value.isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard case .active = states.value.last else {
      Issue.record("expected initial active state")
      return
    }

    turnkey.session = nil
    turnkey.authState = .unAuthenticated

    // The publisher chain hops schedulers; give it a beat.
    for _ in 0..<100 where states.value.last != .unauthenticated {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(states.value.last == .unauthenticated)
  }

  @Test("sessionState emits expired when an active session passes its expiry")
  func sessionStateEmitsOnExpiry() async throws {
    // A real (short) expiry: the coordinator schedules a re-check at the expiry instant.
    // Kept comfortably above scheduling jitter so the first observed state is still active.
    let turnkey = MockTurnkey(session: MockTurnkey.session(expiringIn: 1.0))
    let coordinator = makeCoordinator(turnkey: turnkey)

    let states = LockedBox<[TurnkeySessionState]>([])
    let cancellable = coordinator.sessionStates.sink { state in
      states.mutate { $0.append(state) }
    }
    defer { cancellable.cancel() }

    for _ in 0..<400 where states.value.last != .expired {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(states.value.first.map { if case .active = $0 { true } else { false } } == true)
    #expect(states.value.last == .expired)
  }

  /// The expiry re-check runs on a monotonic Dispatch timer against a wall-clock `expiresAt`. If
  /// the coordinator's clock reads behind the timer when it fires, a single check would re-derive
  /// `.active` and never run again (the CI flake this pins). The check must reschedule itself.
  @Test("sessionState still reaches expired when the clock lags the expiry timer")
  func sessionStateExpiresDespiteLaggingClock() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.session(expiringIn: 0.3))
    // A clock 200 ms behind wall time: the first re-check fires with ~200 ms still "remaining".
    let coordinator = makeCoordinator(turnkey: turnkey, now: { Date().timeIntervalSince1970 - 0.2 })

    let states = LockedBox<[TurnkeySessionState]>([])
    let cancellable = coordinator.sessionStates.sink { state in
      states.mutate { $0.append(state) }
    }
    defer { cancellable.cancel() }

    for _ in 0..<400 where states.value.last != .expired {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(states.value.last == .expired)
  }

  @Test("monitoring fires the expiry hook when an active session dies silently")
  func monitoringFiresHook() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.session(expiringIn: 1.0))
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )
    coordinator.startMonitoring()

    for _ in 0..<400 where hookCalls.delays.isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.delays.count == 1)

    // A later logout emission must not re-fire for the same death.
    turnkey.session = nil
    turnkey.authState = .unAuthenticated
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(hookCalls.delays.count == 1)
  }

  // MARK: - Cold start

  @Test("vendor-wrapped network failures on reads are retried as transient")
  func vendorNetworkErrorIsTransient() async throws {
    let turnkey = MockTurnkey()
    let inner = turnkey.turnkeyClient as! MockTurnkeyClient
    let flaky = FlakyTurnkeyClient(
      wrapping: inner,
      failures: 1,
      error: TurnkeyRequestError.network(URLError(.networkConnectionLost))
    )
    turnkey.turnkeyClient = flaky
    let delays = DelayRecorder()
    let coordinator = makeCoordinator(turnkey: turnkey, delayRecorder: delays)

    _ = try await readActivities(coordinator)

    #expect(delays.delays == [0.5])
    #expect(turnkey.refreshSessionCallCount == 0)
  }

  @Test("call during session restore waits for loading to resolve instead of expiring")
  func waitsOutSessionRestore() async throws {
    let turnkey = MockTurnkey(session: nil)
    turnkey.authState = .loading
    let hookCalls = DelayRecorder()
    // The injected sleep doubles as the restore trigger: after a few checks the "restore"
    // completes with a valid session.
    let checks = LockedBox<Int>(0)
    let coordinator = TurnkeySessionCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) },
      sleep: { _ in
        checks.mutate { $0 += 1 }
        if checks.value == 3 {
          turnkey.session = MockTurnkey.defaultSession()
          turnkey.authState = .authenticated
        }
      }
    )

    _ = try await coordinator.executeRead { session, client in
      try await client.getActivities(self.activitiesBody(organizationId: session.organizationId))
    }

    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    #expect(client.getActivitiesCalls.count == 1)
    #expect(hookCalls.delays.isEmpty)
  }

  @Test("hook re-arms after a re-login and fires again for a second death")
  func hookReArmsAfterReLogin() async throws {
    let turnkey = MockTurnkey()
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )
    coordinator.startMonitoring()
    try await Task.sleep(nanoseconds: 100_000_000)

    turnkey.session = nil
    turnkey.authState = .unAuthenticated
    for _ in 0..<200 where hookCalls.delays.isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.delays.count == 1)

    // Re-login re-arms; a second death must fire again.
    turnkey.session = MockTurnkey.defaultSession()
    turnkey.authState = .authenticated
    try await Task.sleep(nanoseconds: 100_000_000)
    turnkey.session = nil
    turnkey.authState = .unAuthenticated
    for _ in 0..<200 where hookCalls.delays.count == 1 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.delays.count == 2)
  }

  @Test("hook fires when an active session dies through a loading transition")
  func hookFiresThroughLoadingTransition() async throws {
    let turnkey = MockTurnkey()
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )
    coordinator.startMonitoring()

    // Let the initial .active land on the serialized state queue.
    try await Task.sleep(nanoseconds: 100_000_000)

    // Turnkey re-enters loading (e.g. a restore cycle) and comes out unauthenticated.
    turnkey.authState = .loading
    try await Task.sleep(nanoseconds: 100_000_000)
    turnkey.session = nil
    turnkey.authState = .unAuthenticated

    for _ in 0..<200 where hookCalls.delays.isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(hookCalls.delays.count == 1)
  }

  @Test("never-logged-in user gets tokenExpired but the expiry hook stays silent")
  func neverLoggedInHookSilent() async throws {
    let turnkey = MockTurnkey(session: nil)
    let hookCalls = DelayRecorder()
    let coordinator = makeCoordinator(
      turnkey: turnkey,
      onSessionExpired: { hookCalls.record(1) }
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await self.readActivities(coordinator)
    }
    #expect(hookCalls.delays.isEmpty)
  }
}

/// Fails the first `failures` getActivities calls with `error`, then delegates to the wrapped
/// mock. The other protocol methods always delegate.
private final class FlakyTurnkeyClient: TurnkeyClientProtocol, @unchecked Sendable {
  private let inner: MockTurnkeyClient
  private var failuresRemaining: Int
  private let error: Error

  init(wrapping inner: MockTurnkeyClient, failures: Int, error: Error) {
    self.inner = inner
    self.failuresRemaining = failures
    self.error = error
  }

  func getActivities(_ input: TGetActivitiesBody) async throws -> TGetActivitiesResponse {
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw error
    }
    return try await inner.getActivities(input)
  }

  func getWalletAddressBalances(
    _ input: TGetWalletAddressBalancesBody
  ) async throws -> TGetWalletAddressBalancesResponse {
    try await inner.getWalletAddressBalances(input)
  }

  func ethSendTransaction(
    _ input: TEthSendTransactionBody
  ) async throws -> TEthSendTransactionResponse {
    try await inner.ethSendTransaction(input)
  }

  func solSendTransaction(
    _ input: TSolSendTransactionBody
  ) async throws -> TSolSendTransactionResponse {
    try await inner.solSendTransaction(input)
  }

  func getSendTransactionStatus(
    _ input: TGetSendTransactionStatusBody
  ) async throws -> TGetSendTransactionStatusResponse {
    try await inner.getSendTransactionStatus(input)
  }

  func getNonces(_ input: TGetNoncesBody) async throws -> TGetNoncesResponse {
    try await inner.getNonces(input)
  }

  func getActivity(_ input: TGetActivityBody) async throws -> TGetActivityResponse {
    try await inner.getActivity(input)
  }
}

/// Minimal lock-guarded box for collecting publisher emissions across threads in tests.
private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value { lock.withLock { stored } }

  func mutate(_ transform: (inout Value) -> Void) {
    lock.withLock { transform(&stored) }
  }
}
