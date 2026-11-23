import Foundation
import RainCore

/// Session-hardening policy for the Turnkey provider.
///
/// Controls how the SDK guards wallet calls against session expiry and transient failures:
/// expiry is checked before every Turnkey call, sessions inside `refreshBufferSeconds` of
/// expiry are refreshed proactively (when `autoRefresh` is on), a 401/invalid-session failure
/// is refreshed and retried once, and transient failures (HTTP 5xx/429/408, network I/O) on
/// read paths are retried with exponential backoff. Writes (sends, signing) are never retried
/// on transient failures — only after a refresh that proves the original request was rejected
/// before execution.
public struct TurnkeySessionPolicy: Sendable {
  /// Refresh the session when it is within this window of expiring.
  public var refreshBufferSeconds: TimeInterval
  /// When true the SDK calls Turnkey's `refreshSession` itself; when false an expired session
  /// surfaces as `RainError.tokenExpired` and re-auth is the host's job.
  public var autoRefresh: Bool
  /// TTL in seconds requested for refreshed sessions; `nil` uses Turnkey's default (900).
  /// Converted to the vendor's string form at the call.
  public var refreshExpirationSeconds: Int?
  /// Retries (beyond the first attempt) for transient failures on idempotent reads.
  public var maxTransientRetries: Int
  /// First backoff delay; doubles per retry up to `maxRetryDelay`.
  public var initialRetryDelay: TimeInterval
  /// Backoff ceiling.
  public var maxRetryDelay: TimeInterval

  public init(
    refreshBufferSeconds: TimeInterval = 60,
    autoRefresh: Bool = true,
    refreshExpirationSeconds: Int? = nil,
    maxTransientRetries: Int = 2,
    initialRetryDelay: TimeInterval = 0.5,
    maxRetryDelay: TimeInterval = 4
  ) {
    self.refreshBufferSeconds = max(0, refreshBufferSeconds)
    self.autoRefresh = autoRefresh
    self.refreshExpirationSeconds = refreshExpirationSeconds
    self.maxTransientRetries = max(0, maxTransientRetries)
    self.initialRetryDelay = max(0, initialRetryDelay)
    self.maxRetryDelay = max(self.initialRetryDelay, maxRetryDelay)
  }
}

/// The Turnkey session as seen at the Rain SDK boundary. Observable via
/// `TurnkeyProvider.sessionState` so a host can react to a session dying without waiting for
/// a wallet call to fail.
public enum TurnkeySessionState: Equatable, Sendable {
  /// Turnkey is still restoring persisted sessions (app launch).
  case loading
  /// A session exists and its JWT has not expired.
  case active(expiresAtEpochSeconds: TimeInterval)
  /// A session object is still present but its JWT expiry has passed. Re-authenticate.
  case expired
  /// No session (never logged in, logged out, or cleared by Turnkey's expiry timer).
  case unauthenticated
}
