import Combine
import Foundation
import PortalSwift
import RainCore

/// Guards every Portal call: auth classification, refresh-on-auth-failure (host re-mint + client
/// rebuild, single-flighted), transient backoff on reads, and the expiry hook (once per dead token).
internal final class PortalSessionCoordinator: @unchecked Sendable {
  private let policy: PortalSessionPolicy
  private let onSessionTokenNeeded: (@Sendable () async throws -> String?)?
  private let onSessionExpired: (@Sendable () -> Void)?
  private let installToken: @Sendable (String) async throws -> Void
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  private let lock = NSLock()
  private var expiryNotified = false
  private var stopped = false
  /// Bumped per successful install / failed refresh so in-flight callers see what they missed.
  private var tokenEpoch = 0
  private var failedRefreshes = 0
  private var inFlightRefresh: InFlightRefresh?

  /// Identity wrapper so a finished refresh can be cleared by whoever observes it finish.
  private final class InFlightRefresh {
    let task: Task<RefreshOutcome, Never>
    init(_ task: Task<RefreshOutcome, Never>) { self.task = task }
  }
  private var deathCallbacks: [@Sendable () -> Void] = []
  private let stateSubject = CurrentValueSubject<PortalSessionState, Never>(.unknown)

  internal init(
    policy: PortalSessionPolicy = PortalSessionPolicy(),
    onSessionTokenNeeded: (@Sendable () async throws -> String?)? = nil,
    onSessionExpired: (@Sendable () -> Void)? = nil,
    installToken: @escaping @Sendable (String) async throws -> Void = { _ in },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) {
    self.policy = policy
    self.onSessionTokenNeeded = onSessionTokenNeeded
    self.onSessionExpired = onSessionExpired
    self.installToken = installToken
    self.sleep = sleep
  }

  internal func currentState() -> PortalSessionState {
    stateSubject.value
  }

  internal var sessionStates: AnyPublisher<PortalSessionState, Never> {
    stateSubject.removeDuplicates().eraseToAnyPublisher()
  }

  /// Runs once per session death, before the host hook.
  internal func onSessionDeath(_ callback: @escaping @Sendable () -> Void) {
    lock.withLock { deathCallbacks.append(callback) }
  }

  /// Permanently silences the hook.
  internal func stop() {
    lock.withLock { stopped = true }
  }

  /// Idempotent call: transient failures are retried.
  internal func executeRead<T>(_ block: () async throws -> T) async throws -> T {
    try await execute(idempotent: true, block)
  }

  /// Non-idempotent call: retried only once, after a token refresh.
  internal func executeWrite<T>(_ block: () async throws -> T) async throws -> T {
    try await execute(idempotent: false, block)
  }

  /// Re-mints and rebuilds now; throws `.tokenExpired` (after the hook) on failure.
  internal func refreshNow() async throws {
    let outcome = await runSingleFlight(joinExisting: true) { await self.refreshOutcome() }
    if case .dead(let cause) = outcome { throw expiredError(cause) }
  }

  /// Installs a host-minted token; waits out an in-flight refresh rather than joining it, so the
  /// host's token is actually the one installed. A token that cannot be installed throws
  /// `.invalidConfig` and leaves the current client, state and hook untouched — Portal never
  /// rejected the installed token, so this is not a session death.
  internal func installNow(_ token: String) async throws {
    guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw RainError.invalidConfig(details: "Portal session token must not be empty")
    }
    let outcome = await runSingleFlight(joinExisting: false) {
      let previous = self.stateSubject.value
      let outcome = await self.installOutcome(token)
      if case .dead = outcome { self.stateSubject.send(previous) }
      return outcome
    }
    if case .dead(let cause) = outcome {
      let reason = cause.map { "\($0)" } ?? "unknown error"
      throw RainError.invalidConfig(
        details: "Portal session token could not be installed: \(reason)"
      )
    }
  }

  private func execute<T>(idempotent: Bool, _ block: () async throws -> T) async throws -> T {
    var refreshedAfterAuthFailure = false
    var transientRetries = 0
    var backoff = policy.initialRetryDelay
    while true {
      // Pre-call guard: a known-dead token is re-minted first or fails fast.
      if stateSubject.value == .expired {
        if refreshedAfterAuthFailure || !canRefresh { throw expiredError() }
        refreshedAfterAuthFailure = true
        try await refreshOrExpire(epochSeen: currentEpoch(), failuresSeen: currentFailures(), cause: nil)
      }
      let epoch = currentEpoch()
      let failures = currentFailures()
      do {
        let result = try await block()
        markActive()
        return result
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw error }
        // Portal rejects a bad token before executing, so one retry is safe for sends too.
        if isAuthFailure(error) {
          if refreshedAfterAuthFailure { throw expiredError(error) }
          refreshedAfterAuthFailure = true
          // Swapped while in flight: the failure belongs to the old token.
          if currentEpoch() != epoch { continue }
          if !canRefresh { throw expiredError(error) }
          try await refreshOrExpire(epochSeen: epoch, failuresSeen: failures, cause: error)
          continue
        }
        if idempotent, transientRetries < policy.maxTransientRetries, isTransient(error) {
          transientRetries += 1
          RainLogger.warning(
            "Rain SDK: transient Portal failure, retry \(transientRetries)/\(policy.maxTransientRetries): \(error)"
          )
          try await sleep(backoff)
          backoff = min(backoff * 2, policy.maxRetryDelay)
          continue
        }
        throw error
      }
    }
  }

  private var canRefresh: Bool { policy.autoRefresh && onSessionTokenNeeded != nil }

  private func currentEpoch() -> Int { lock.withLock { tokenEpoch } }
  private func currentFailures() -> Int { lock.withLock { failedRefreshes } }

  /// Reported instead of thrown so the single-flight slot is released before the hook fires.
  private enum RefreshOutcome {
    case fresh
    case dead(Error?)
  }

  private func refreshOrExpire(epochSeen: Int, failuresSeen: Int, cause: Error?) async throws {
    let outcome = await runSingleFlight(joinExisting: true) {
      // Another caller already swapped or already failed on this token: share it.
      if self.currentEpoch() != epochSeen { return .fresh }
      if self.currentFailures() != failuresSeen { return .dead(nil) }
      return await self.refreshOutcome()
    }
    if case .dead(let refreshCause) = outcome { throw expiredError(refreshCause ?? cause) }
  }

  /// Runs `work` in the single refresh slot; `joinExisting` callers adopt an in-flight outcome,
  /// others wait for it to finish and then run their own.
  private func runSingleFlight(
    joinExisting: Bool,
    _ work: @escaping @Sendable () async -> RefreshOutcome
  ) async -> RefreshOutcome {
    while true {
      let (slot, owned): (InFlightRefresh, Bool) = lock.withLock {
        if let existing = inFlightRefresh { return (existing, false) }
        let created = InFlightRefresh(Task { await work() })
        inFlightRefresh = created
        return (created, true)
      }
      let outcome = await slot.task.value
      // Whoever sees it finish clears it, so nobody joins a refresh for a previous token.
      lock.withLock { if inFlightRefresh === slot { inFlightRefresh = nil } }
      if owned || joinExisting { return outcome }
    }
  }

  private func refreshOutcome() async -> RefreshOutcome {
    let outcome = await attemptRefresh()
    if case .dead = outcome { lock.withLock { failedRefreshes += 1 } }
    return outcome
  }

  private func attemptRefresh() async -> RefreshOutcome {
    guard let mint = onSessionTokenNeeded else { return .dead(nil) }
    stateSubject.send(.refreshing)
    let token: String?
    do {
      token = try await mint()
    } catch {
      RainLogger.warning("Rain SDK: Portal session token re-mint failed: \(error)")
      return .dead(error)
    }
    guard let token, !token.trimmingCharacters(in: .whitespaces).isEmpty else {
      RainLogger.warning("Rain SDK: host declined to re-mint the Portal session token")
      return .dead(nil)
    }
    return await installOutcome(token)
  }

  private func installOutcome(_ token: String) async -> RefreshOutcome {
    stateSubject.send(.refreshing)
    do {
      try await installToken(token)
    } catch {
      RainLogger.warning("Rain SDK: Portal client rebuild with the new session token failed: \(error)")
      return .dead(error)
    }
    lock.withLock {
      tokenEpoch += 1
      expiryNotified = false
    }
    markActive()
    return .fresh
  }

  private func markActive() {
    if !lock.withLock({ stopped }) { stateSubject.send(.active) }
  }

  private func expiredError(_ cause: Error? = nil) -> RainError {
    if let cause {
      RainLogger.warning("Rain SDK: Portal session token is no longer usable: \(cause)")
    }
    notifyDeath()
    return .tokenExpired
  }

  private func notifyDeath() {
    stateSubject.send(.expired)
    let callbacks: [@Sendable () -> Void]? = lock.withLock {
      guard !stopped, !expiryNotified else { return nil }
      expiryNotified = true
      return deathCallbacks
    }
    guard let callbacks else { return }
    callbacks.forEach { $0() }
    onSessionExpired?()
  }

  private func isAuthFailure(_ error: Error) -> Bool {
    if let rain = error as? RainError { return rain == .tokenExpired }
    return PortalErrorMapping.mapAuthOrNil(error) == .tokenExpired
  }

  private func isTransient(_ error: Error) -> Bool {
    if PortalErrorMapping.isTransient(error) { return true }
    switch error as? RainError {
    case .networkError: return true
    case .providerError(let underlying): return isTransient(underlying)
    default: break
    }
    // Walk the underlying-error chain so wrapped URLErrors retry like bare ones.
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
}
