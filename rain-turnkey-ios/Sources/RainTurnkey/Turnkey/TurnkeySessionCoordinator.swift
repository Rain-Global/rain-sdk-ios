import Combine
import Foundation
import TurnkeyHttp
import TurnkeySwift
import RainCore

/// Guards every Turnkey call behind session-expiry checks, proactive refresh, refresh-on-401
/// retry, and transient-failure backoff, per `TurnkeySessionPolicy`. Same shape as the Portal and
/// Privy coordinators, adapted to Turnkey's externally-owned session.
///
/// Terminal auth failures always surface as `RainError.tokenExpired` and fire the host's
/// `onSessionExpired` hook once per session death; the hook re-arms when a live session is
/// seen again.
internal final class TurnkeySessionCoordinator: @unchecked Sendable {
  private let turnkey: TurnkeyContextProtocol
  private let policy: TurnkeySessionPolicy
  private let onSessionExpired: (@Sendable () -> Void)?
  private let now: @Sendable () -> TimeInterval
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  private let lock = NSLock()
  private var refreshTask: Task<Void, Error>?
  private var expiryNotified = false
  /// Whether a session was ever observed — only an existing session can "die".
  private var sawSession = false
  /// Set by `stopMonitoring` (provider `close()`): a discarded provider never notifies again.
  private var stopped = false
  private var monitorCancellable: AnyCancellable?
  /// Serializes state delivery: the auth/session publishers emit on the main thread while the
  /// expiry re-check fires on a global queue, and Combine expects serialized delivery.
  private let stateQueue = DispatchQueue(label: "com.rain.sdk.turnkey.session-state")

  internal init(
    turnkey: TurnkeyContextProtocol,
    policy: TurnkeySessionPolicy = TurnkeySessionPolicy(),
    onSessionExpired: (@Sendable () -> Void)? = nil,
    now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) {
    self.turnkey = turnkey
    self.policy = policy
    self.onSessionExpired = onSessionExpired
    self.now = now
    self.sleep = sleep
  }

  /// Snapshot of the session state as seen right now.
  internal func currentState() -> TurnkeySessionState {
    deriveState(auth: turnkey.authState, session: turnkey.session)
  }

  /// The session state over time. Re-derives on every Turnkey auth/session emission, and —
  /// because a session passing its expiry emits nothing by itself — schedules one re-check
  /// at the active session's expiry instant.
  internal var sessionStates: AnyPublisher<TurnkeySessionState, Never> {
    let derive: @Sendable (AuthState, Session?) -> TurnkeySessionState = { [now] auth, session in
      Self.deriveState(auth: auth, session: session, now: now())
    }
    let now = self.now
    return turnkey.authStatePublisher
      .combineLatest(turnkey.sessionPublisher)
      .map { auth, session -> AnyPublisher<TurnkeySessionState, Never> in
        let state = derive(auth, session)
        guard case .active(let expiresAt) = state else {
          return Just(state).eraseToAnyPublisher()
        }
        return Just(state)
          .append(Self.expiryRecheck(expiresAt: expiresAt, now: now))
          .eraseToAnyPublisher()
      }
      .switchToLatest()
      .receive(on: stateQueue)
      .removeDuplicates()
      .eraseToAnyPublisher()
  }

  /// Emits `.expired` once `now()` has passed `expiresAt`, re-checking until it has. Within one
  /// `switchToLatest` branch the auth state and session are fixed (a change would start a new
  /// branch), so expiry is the only thing left to derive. The timer runs on a monotonic Dispatch
  /// clock while `expiresAt` is wall time, so a single check can fire while `now()` still reads
  /// a hair short of expiry (clock skew, rounding, NTP adjustment) — a one-shot check would then
  /// re-derive `.active`, be dropped by `removeDuplicates`, and the session would never report
  /// expired. Each retry is padded by `expiryRecheckPadding` so the loop converges.
  private static func expiryRecheck(
    expiresAt: TimeInterval,
    now: @escaping @Sendable () -> TimeInterval
  ) -> AnyPublisher<TurnkeySessionState, Never> {
    Deferred {
      Just(())
        .delay(
          for: .seconds(max(0, expiresAt - now()) + expiryRecheckPadding),
          scheduler: DispatchQueue.global()
        )
        .flatMap { _ -> AnyPublisher<TurnkeySessionState, Never> in
          guard expiresAt <= now() else {
            return expiryRecheck(expiresAt: expiresAt, now: now)
          }
          return Just(.expired).eraseToAnyPublisher()
        }
    }
    .eraseToAnyPublisher()
  }

  private static let expiryRecheckPadding: TimeInterval = 0.05

  /// Idempotent call (balances, history, status reads): transient failures are retried.
  internal func executeRead<T>(
    _ block: (Session, any TurnkeyClientProtocol) async throws -> T
  ) async throws -> T {
    try await execute(idempotent: true, block)
  }

  /// Non-idempotent call (sends, signing): retried only after a session refresh on 401.
  internal func executeWrite<T>(
    _ block: (Session, any TurnkeyClientProtocol) async throws -> T
  ) async throws -> T {
    try await execute(idempotent: false, block)
  }

  /// Forces a session refresh through Turnkey regardless of remaining lifetime. Throws
  /// `RainError.tokenExpired` (after firing the expiry hook) when the refresh fails.
  internal func refreshNow() async throws {
    if turnkey.session != nil {
      lock.withLock { sawSession = true }
    }
    try await performRefreshOrExpire()
    lock.withLock { expiryNotified = false }
  }

  /// Stops the passive watcher permanently. A later `startMonitoring()` is a no-op, so a
  /// discarded provider can never fire its expiry hook again.
  internal func stopMonitoring() {
    lock.withLock {
      stopped = true
      monitorCancellable?.cancel()
      monitorCancellable = AnyCancellable {}
    }
  }

  /// Starts the passive watcher that fires `onSessionExpired` when an active session dies
  /// without any Rain call in flight (Turnkey's expiry timer clearing it, a logout, or the
  /// JWT lapsing while the app is backgrounded). Safe to call more than once.
  internal func startMonitoring() {
    // Reserve under the lock, subscribe outside it: Combine delivers the current value
    // synchronously on subscribe, and the sink itself takes this (non-reentrant) lock.
    let shouldStart: Bool = lock.withLock {
      guard monitorCancellable == nil else { return false }
      monitorCancellable = AnyCancellable {}
      return true
    }
    guard shouldStart else { return }

    var previous: TurnkeySessionState?
    let cancellable = sessionStates.sink { [weak self] state in
      guard let self else { return }
      switch state {
      case .active:
        self.lock.withLock {
          self.sawSession = true
          self.expiryNotified = false
        }
      case .expired, .unauthenticated:
        if case .active = previous { self.notifyExpired() }
      case .loading:
        // Transitional — keep `previous` so active → loading → unauthenticated still
        // reads as a death of the active session.
        return
      }
      previous = state
    }
    lock.withLock { monitorCancellable = cancellable }
  }

  private func execute<T>(
    idempotent: Bool,
    _ block: (Session, any TurnkeyClientProtocol) async throws -> T
  ) async throws -> T {
    var refreshedAfterAuthFailure = false
    var transientRetries = 0
    var backoff = policy.initialRetryDelay
    while true {
      let session = try await ensureValidSession()
      guard let client = turnkey.turnkeyClient else { throw expiredError() }
      do {
        return try await block(session, client)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw error }
        if isAuthFailure(error) {
          // A 401 means Turnkey rejected the request before executing it, so a single
          // refresh-and-retry is safe for signing. NOT for the vendor's typed send calls, which
          // poll inside the call — a 401 there may follow an accepted submit. The send paths
          // therefore never let a post-submit 401 reach here (`sortedSendOutcome`).
          if refreshedAfterAuthFailure || !policy.autoRefresh { throw expiredError(error) }
          refreshedAfterAuthFailure = true
          try await performRefreshOrExpire()
          continue
        }
        if idempotent, transientRetries < policy.maxTransientRetries, isTransient(error) {
          transientRetries += 1
          RainLogger.warning(
            "Rain SDK: transient Turnkey failure, retry \(transientRetries)/\(policy.maxTransientRetries): \(error)"
          )
          try await sleep(backoff)
          backoff = min(backoff * 2, policy.maxRetryDelay)
          continue
        }
        throw error
      }
    }
  }

  /// The current session, refreshed first when it is expired or within the refresh buffer.
  /// Throws `RainError.tokenExpired` when no usable session can be produced.
  private func ensureValidSession() async throws -> Session {
    // Turnkey restores persisted sessions asynchronously after launch; a call racing that
    // restore must wait it out rather than misreport a valid session as expired.
    if turnkey.session == nil, case .loading = turnkey.authState {
      var checks = 0
      while checks < Self.authRestoreMaxChecks, case .loading = turnkey.authState {
        checks += 1
        try await sleep(Self.authRestoreCheckInterval)
      }
    }
    guard let session = turnkey.session else { throw expiredError() }
    lock.withLock { sawSession = true }
    let remaining = session.exp - now()
    if remaining > policy.refreshBufferSeconds {
      lock.withLock { expiryNotified = false }
      return session
    }
    if !policy.autoRefresh {
      if remaining <= 0 { throw expiredError() }
      // Inside the buffer but not yet expired: without autoRefresh the call proceeds.
      return session
    }
    // A concurrent caller may already be refreshing; performRefresh single-flights.
    if let current = turnkey.session, current.exp - now() > policy.refreshBufferSeconds {
      return current
    }
    do {
      try await performRefresh()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Only Turnkey rejecting the refresh, or a session already past `exp`, is a death. A
      // transient failure inside the buffer proceeds on the still-valid session rather than
      // logging the user out over a network blip.
      guard !isAuthFailure(error), let current = turnkey.session, current.exp - now() > 0 else {
        throw expiredError(error)
      }
      RainLogger.warning(
        "Rain SDK: Turnkey proactive refresh failed; proceeding on the current session (\(Int(current.exp - now()))s left): \(error)"
      )
      return current
    }
    guard let refreshed = turnkey.session else { throw expiredError() }
    return refreshed
  }

  /// Single-flighted refresh; a failure surfaces as `RainError.tokenExpired`.
  private func performRefreshOrExpire() async throws {
    do {
      try await performRefresh()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw expiredError(error)
    }
  }

  /// Single-flighted refresh through Turnkey; rethrows the vendor error as-is.
  private func performRefresh() async throws {
    let task: Task<Void, Error> = lock.withLock {
      if let existing = refreshTask { return existing }
      let task = Task { [turnkey, policy] in
        try await turnkey.refreshTurnkeySession(
          expirationSeconds: policy.refreshExpirationSeconds.map(String.init)
        )
      }
      refreshTask = task
      return task
    }
    defer {
      lock.withLock { if refreshTask == task { refreshTask = nil } }
    }
    do {
      try await task.value
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      RainLogger.warning("Rain SDK: Turnkey session refresh failed: \(error)")
      throw error
    }
  }

  private func expiredError(_ cause: Error? = nil) -> RainError {
    if let cause {
      RainLogger.warning("Rain SDK: Turnkey session is no longer usable: \(cause)")
    }
    notifyExpired()
    return .tokenExpired
  }

  private func notifyExpired() {
    guard let onSessionExpired else { return }
    let shouldNotify: Bool = lock.withLock {
      // A closed coordinator belongs to a discarded provider — it must never notify.
      guard !stopped else { return false }
      // Never logged in is not a session death: only notify once a session has been seen.
      guard sawSession, !expiryNotified else { return false }
      expiryNotified = true
      return true
    }
    guard shouldNotify else { return }
    onSessionExpired()
  }

  private func deriveState(auth: AuthState, session: Session?) -> TurnkeySessionState {
    Self.deriveState(auth: auth, session: session, now: now())
  }

  private static func deriveState(
    auth: AuthState,
    session: Session?,
    now: TimeInterval
  ) -> TurnkeySessionState {
    if case .loading = auth { return .loading }
    guard let session, case .authenticated = auth else { return .unauthenticated }
    return session.exp <= now ? .expired : .active(expiresAtEpochSeconds: session.exp)
  }

  private func isAuthFailure(_ error: Error) -> Bool {
    if let history = error as? TurnkeyHistoryError { return history.statusCode == 401 }
    // `.from` unwraps TurnkeySwiftError wrappers and TurnkeyRequestError.apiError(401) alike.
    return RainError.from(underlying: error) == .tokenExpired
  }

  private func isTransient(_ error: Error) -> Bool {
    if let history = error as? TurnkeyHistoryError {
      return Self.isTransientStatus(history.statusCode)
    }
    if let request = unwrappedRequestError(error) {
      if case .apiError(let status, _) = request, let status {
        return Self.isTransientStatus(status)
      }
      if case .network(let underlying) = request {
        // The vendor's own network bucket — transient unless it was a cancellation.
        let nsError = underlying as NSError
        return nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled
      }
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return nsError.code != NSURLErrorCancelled
    }
    return false
  }

  /// Digs a `TurnkeyRequestError` out of the SDK's wrapper shapes (bounded depth).
  private func unwrappedRequestError(_ error: Error) -> TurnkeyRequestError? {
    var current: Error = error
    for _ in 0..<8 {
      if let request = current as? TurnkeyRequestError {
        if case .sdkError(let underlying) = request { current = underlying; continue }
        if case .unknown(let underlying) = request { current = underlying; continue }
        return request
      }
      guard let swiftError = current as? TurnkeySwiftError,
            let underlying = Self.underlying(of: swiftError)
      else { return nil }
      current = underlying
    }
    return nil
  }

  private static func underlying(of error: TurnkeySwiftError) -> Error? {
    switch error {
    case .failedToSignPayload(let underlying),
         .failedToFetchWallets(let underlying),
         .failedToStoreSession(let underlying),
         .failedToRefreshSession(let underlying),
         .failedToClearSession(let underlying):
      return underlying
    default:
      return nil
    }
  }

  private static func isTransientStatus(_ status: Int) -> Bool {
    status == 408 || status == 429 || (500...599).contains(status)
  }

  /// Bounded wait for Turnkey's async session restore (~10s of real time at 50ms checks).
  private static let authRestoreMaxChecks = 200
  private static let authRestoreCheckInterval: TimeInterval = 0.05
}
