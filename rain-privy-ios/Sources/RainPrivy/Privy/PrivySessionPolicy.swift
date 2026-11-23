import Foundation

/// Session-hardening policy for the Privy provider.
///
/// Privy differs from Turnkey: the Privy SDK refreshes its own session internally before every
/// wallet and indexer call, and exposes no JWT expiry. So there is no proactive-refresh window
/// to configure — hardening here is auth-state guarding, a re-auth hook, and transient-failure
/// backoff. An auth failure that survives Privy's own internal refresh means the session is
/// truly dead and surfaces as `RainError.tokenExpired` (never retried by Rain).
public struct PrivySessionPolicy: Sendable {
  /// Retries (beyond the first attempt) for transient network failures on idempotent reads.
  /// Writes (sends, signing) are never retried.
  public var maxTransientRetries: Int
  /// First backoff delay; doubles per retry up to `maxRetryDelay`.
  public var initialRetryDelay: TimeInterval
  /// Backoff ceiling.
  public var maxRetryDelay: TimeInterval

  public init(
    maxTransientRetries: Int = 2,
    initialRetryDelay: TimeInterval = 0.5,
    maxRetryDelay: TimeInterval = 4
  ) {
    self.maxTransientRetries = max(0, maxTransientRetries)
    self.initialRetryDelay = max(0, initialRetryDelay)
    self.maxRetryDelay = max(self.initialRetryDelay, maxRetryDelay)
  }
}

/// The Privy session as seen at the Rain SDK boundary. Observable via
/// `PrivyProvider.sessionState` so a host can react to a session dying without waiting for a
/// wallet call to fail. Privy exposes no JWT expiry, so unlike Turnkey there is no `expired`
/// state — a dead session surfaces as `.unauthenticated` once Privy clears it.
public enum PrivySessionState: Equatable, Sendable {
  /// Privy is still restoring persisted credentials (app launch).
  case loading
  /// An authenticated session exists.
  case active
  /// A prior session was restored but could not be verified (typically offline). Recoverable:
  /// Privy re-verifies via `onNetworkRestored()` when connectivity returns.
  case unverified
  /// No session (never logged in, logged out, or the session died and Privy cleared it).
  case unauthenticated
}
