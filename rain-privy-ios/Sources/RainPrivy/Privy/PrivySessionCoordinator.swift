import Combine
import Foundation
import PrivySDK
import RainCore

/// Narrow seam over the vendor `Privy` singleton's auth surface, so the session coordinator
/// can be unit-tested without the vendor SDK (mirrors `PrivyWalletSource` for wallets). Vends
/// derived `PrivySessionState` values rather than vendor `AuthState` — the vendor's
/// `.authenticated` case carries a `PrivyUser` existential a test cannot construct.
protocol PrivyAuthSource: Sendable {
  /// The session-state stream, derived from the vendor's single-consumer auth-state stream.
  /// Consumed exactly once, by the coordinator.
  var sessionStateStream: AsyncStream<PrivySessionState> { get }
  /// Synchronous snapshot that never triggers a vendor-side refresh.
  func currentSessionState() -> PrivySessionState
  /// Refreshes the session via `PrivyUser.refresh()`; throws when no user exists or it fails.
  func refreshUser() async throws
}

struct LivePrivyAuthSource: PrivyAuthSource {
  let privy: any Privy

  var sessionStateStream: AsyncStream<PrivySessionState> {
    let vendorStream = privy.authStateStream
    return AsyncStream { continuation in
      let task = Task {
        for await state in vendorStream {
          continuation.yield(Self.derive(state))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func currentSessionState() -> PrivySessionState {
    Self.derive(privy.getAuthStateWithoutRefresh())
  }

  func refreshUser() async throws {
    guard let user = await privy.getUser() else { throw RainError.tokenExpired }
    try await user.refresh()
  }

  static func derive(_ auth: AuthState) -> PrivySessionState {
    switch auth {
    case .notReady: return .loading
    case .authenticated: return .active
    case .authenticatedUnverified: return .unverified
    case .unauthenticated: return .unauthenticated
    @unknown default:
      // A future vendor state is non-committal: treat as transitional, never as a death.
      return .loading
    }
  }
}

/// Guards every Privy call behind auth-state checks and transient-failure backoff, and turns a
/// dying session into a host-visible signal (the `onSessionExpired` hook plus `sessionStates`).
///
/// Unlike the Turnkey coordinator there is no refresh machinery: the Privy SDK single-flights
/// its own session refresh internally before every wallet/indexer call, so an auth failure that
/// reaches Rain means Privy already tried and the session is truly dead. Terminal auth failures
/// surface as `RainError.tokenExpired` and fire the hook once per session death; the hook
/// re-arms when a live session is seen again.
///
/// Touches the vendor only from `create`-time paths — never from `init` — so a provider built
/// purely to read `id`/`capabilities` stays inert.
internal final class PrivySessionCoordinator: @unchecked Sendable {
  private let auth: any PrivyAuthSource
  private let policy: PrivySessionPolicy
  private let onSessionExpired: (@Sendable () -> Void)?
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  private let lock = NSLock()
  private var expiryNotified = false
  /// Whether an authenticated session was ever observed — only an existing session can "die".
  private var sawSession = false
  /// Runs when an active session dies (before the host hook) — e.g. cached-account eviction.
  private var deathCallbacks: [@Sendable () -> Void] = []
  private var stateSubject: CurrentValueSubject<PrivySessionState, Never>?
  private var streamTask: Task<Void, Never>?
  private var previousState: PrivySessionState?
  private var stopped = false

  internal init(
    auth: any PrivyAuthSource,
    policy: PrivySessionPolicy = PrivySessionPolicy(),
    onSessionExpired: (@Sendable () -> Void)? = nil,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) {
    self.auth = auth
    self.policy = policy
    self.onSessionExpired = onSessionExpired
    self.sleep = sleep
  }

  /// Snapshot of the session state as seen right now (never triggers a vendor refresh).
  internal func currentState() -> PrivySessionState {
    auth.currentSessionState()
  }

  /// The session state over time, driven by Privy's own auth-state stream. First access
  /// subscribes the coordinator to the vendor stream (single-consumer) and re-broadcasts.
  internal var sessionStates: AnyPublisher<PrivySessionState, Never> {
    ensureStreamStarted().removeDuplicates().eraseToAnyPublisher()
  }

  /// Registers a callback invoked once per session death, before the host hook.
  internal func onSessionDeath(_ callback: @escaping @Sendable () -> Void) {
    lock.withLock { deathCallbacks.append(callback) }
  }

  /// Starts the passive watcher that fires `onSessionExpired` (and the death callbacks) when
  /// an active session dies without any Rain call in flight. Safe to call more than once.
  ///
  /// Only active→unauthenticated transitions notify: a session that is already dead when
  /// monitoring starts surfaces through `currentState()` or the first wallet call instead.
  internal func startMonitoring() {
    if lock.withLock({ stopped }) {
      RainLogger.warning(
        "Rain SDK: Privy session watcher not started — this provider was closed; build a new one"
      )
      return
    }
    _ = ensureStreamStarted()
  }

  /// Stops the passive watcher permanently, so a discarded provider can never fire its hook.
  internal func stopMonitoring() {
    lock.withLock {
      stopped = true
      streamTask?.cancel()
      streamTask = nil
    }
  }

  /// Idempotent call (address reads, history): transient failures are retried with backoff.
  internal func executeRead<T>(_ block: () async throws -> T) async throws -> T {
    try await execute(idempotent: true, block)
  }

  /// Non-idempotent call (sends, signing): never retried.
  internal func executeWrite<T>(_ block: () async throws -> T) async throws -> T {
    try await execute(idempotent: false, block)
  }

  /// The pre-call guard alone, for call sites whose bodies cannot be passed as a closure
  /// (actor-isolated send paths). Pair with `classifyFailure`.
  internal func preflight() async throws {
    try await awaitAuthReady()
    switch auth.currentSessionState() {
    // Note: this does not re-arm the hook — Privy's local state can keep reading
    // authenticated after a server-side death, and each failing call must not re-fire.
    // Re-arming happens on the watcher's transition back to active (a real re-login).
    case .active:
      lock.withLock { sawSession = true }
    case .unauthenticated:
      throw expiredError()
    // Unverified proceeds: Privy's own per-call refresh settles whether it is usable.
    case .loading, .unverified:
      break
    }
  }

  /// Classifies a failure from a guarded call: terminal auth failures become
  /// `RainError.tokenExpired` (firing the hook); everything else passes through.
  internal func classifyFailure(_ error: Error) -> Error {
    if error is CancellationError { return error }
    if isAuthFailure(error) { return expiredError(error) }
    return error
  }

  /// Forces a session refresh through Privy (`PrivyUser.refresh`). Throws
  /// `RainError.tokenExpired` (after firing the expiry hook) when no user exists or the
  /// refresh fails.
  internal func refreshNow() async throws {
    let state = auth.currentSessionState()
    if state == .active || state == .unverified {
      lock.withLock { sawSession = true }
    }
    do {
      try await auth.refreshUser()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      RainLogger.warning("Rain SDK: Privy session refresh failed: \(error)")
      throw expiredError(error)
    }
    lock.withLock { expiryNotified = false }
  }

  private func execute<T>(idempotent: Bool, _ block: () async throws -> T) async throws -> T {
    try await preflight()
    var transientRetries = 0
    var backoff = policy.initialRetryDelay
    while true {
      do {
        return try await block()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw error }
        // Privy already retried its own internal refresh before this surfaced, so an auth
        // failure here is terminal — never retried by Rain.
        if isAuthFailure(error) { throw expiredError(error) }
        if idempotent, transientRetries < policy.maxTransientRetries, isTransient(error) {
          transientRetries += 1
          RainLogger.warning(
            "Rain SDK: transient Privy failure, retry \(transientRetries)/\(policy.maxTransientRetries): \(error)"
          )
          try await sleep(backoff)
          backoff = min(backoff * 2, policy.maxRetryDelay)
          continue
        }
        throw error
      }
    }
  }

  /// Privy restores persisted credentials asynchronously after launch; a call racing that
  /// restore waits it out (bounded) rather than misreporting a valid session as dead.
  private func awaitAuthReady() async throws {
    guard case .loading = auth.currentSessionState() else { return }
    var checks = 0
    while checks < Self.authRestoreMaxChecks,
          case .loading = auth.currentSessionState() {
      checks += 1
      try await sleep(Self.authRestoreCheckInterval)
    }
  }

  private func ensureStreamStarted() -> CurrentValueSubject<PrivySessionState, Never> {
    let (subject, needsTask): (CurrentValueSubject<PrivySessionState, Never>, Bool) =
      lock.withLock {
        if let existing = stateSubject { return (existing, false) }
        let initial = auth.currentSessionState()
        let subject = CurrentValueSubject<PrivySessionState, Never>(initial)
        stateSubject = subject
        if initial == .active {
          sawSession = true
          previousState = .active
        }
        return (subject, !stopped)
      }
    guard needsTask else { return subject }

    let task = Task { [weak self, auth] in
      for await state in auth.sessionStateStream {
        guard let self else { return }
        self.handle(state)
      }
    }
    lock.withLock {
      if stopped {
        task.cancel()
      } else {
        streamTask = task
      }
    }
    return subject
  }

  private func handle(_ state: PrivySessionState) {
    let subject = lock.withLock { stateSubject }
    subject?.send(state)
    switch state {
    case .active:
      lock.withLock {
        sawSession = true
        expiryNotified = false
        previousState = .active
      }
    case .unauthenticated:
      let wasActive: Bool = lock.withLock {
        let was = previousState == .active
        previousState = .unauthenticated
        return was
      }
      if wasActive { notifyDeath() }
    // Transitional (startup restore / offline-unverified): keep `previous` so
    // active → loading/unverified → unauthenticated still reads as a death.
    case .loading, .unverified:
      break
    }
  }

  private func expiredError(_ cause: Error? = nil) -> RainError {
    if let cause {
      RainLogger.warning("Rain SDK: Privy session is no longer usable: \(cause)")
    }
    notifyDeath()
    return .tokenExpired
  }

  private func notifyDeath() {
    let callbacks: [@Sendable () -> Void]? = lock.withLock {
      // A closed coordinator belongs to a discarded provider — it must never notify.
      guard !stopped else { return nil }
      // Never logged in is not a session death: only notify once a session has been seen.
      guard sawSession, !expiryNotified else { return nil }
      expiryNotified = true
      return deathCallbacks
    }
    guard let callbacks else { return }
    callbacks.forEach { $0() }
    onSessionExpired?()
  }

  private func isAuthFailure(_ error: Error) -> Bool {
    if let rain = error as? RainError { return rain == .tokenExpired }
    return PrivyErrorMapping.map(error) == .tokenExpired
  }

  private func isTransient(_ error: Error) -> Bool {
    // Vendor errors wrap their transport failures; walk the underlying-error chain so an
    // indexer call failing on connectivity retries like a bare URLError would.
    var current: Error = error
    for _ in 0..<8 {
      let nsError = current as NSError
      if nsError.domain == NSURLErrorDomain {
        // Cancellation is not transient; -1013 is an auth challenge, not a network blip.
        return nsError.code != NSURLErrorCancelled
          && nsError.code != NSURLErrorUserAuthenticationRequired
      }
      guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
        return false
      }
      current = underlying
    }
    return false
  }

  /// Bounded wait for Privy's async credential restore (~10s of real time at 50ms checks).
  private static let authRestoreMaxChecks = 200
  private static let authRestoreCheckInterval: TimeInterval = 0.05
}
