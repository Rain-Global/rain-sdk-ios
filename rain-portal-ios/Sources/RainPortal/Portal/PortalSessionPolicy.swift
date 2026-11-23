import Foundation

/// Session-hardening policy for the Portal provider. Portal exposes no auth state, expiry or
/// token swap, so refresh = host re-mint (`onSessionTokenNeeded`) + vendor client rebuild.
public struct PortalSessionPolicy: Sendable {
  /// Re-mint and retry once on a rejected token (Portal rejects a bad token before executing,
  /// so the retry is safe for sends too).
  public var autoRefresh: Bool
  /// Retries for HTTP 5xx/429/408 and network failures on idempotent reads.
  public var maxTransientRetries: Int
  /// First backoff delay; doubles per retry up to `maxRetryDelay`.
  public var initialRetryDelay: TimeInterval
  /// Backoff ceiling.
  public var maxRetryDelay: TimeInterval

  public init(
    autoRefresh: Bool = true,
    maxTransientRetries: Int = 2,
    initialRetryDelay: TimeInterval = 0.5,
    maxRetryDelay: TimeInterval = 4
  ) {
    self.autoRefresh = autoRefresh
    self.maxTransientRetries = max(0, maxTransientRetries)
    self.initialRetryDelay = max(0, initialRetryDelay)
    self.maxRetryDelay = max(self.initialRetryDelay, maxRetryDelay)
  }
}

/// The Portal session as seen at the Rain SDK boundary (via `PortalProvider.sessionState`).
/// Driven by call outcomes — Portal has nothing to watch passively — so it lags until a call runs.
public enum PortalSessionState: Equatable, Sendable {
  /// No Portal call has completed yet for this token.
  case unknown
  /// The last Portal call or token refresh succeeded.
  case active
  /// A re-minted token is being installed.
  case refreshing
  /// Portal rejected the token and no fresh one could be installed; re-auth is required.
  case expired
}
