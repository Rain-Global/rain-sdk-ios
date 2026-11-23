import Foundation

/// Admin withdrawal signature and its metadata, as returned by
/// `GET /v1/issuing/users/{userId}/signatures/withdrawals`. Passed whole to
/// `withdrawCollateral` / `prepareWithdrawal` / `estimateWithdrawalFee`.
public struct RainAdminSignature: Sendable, Hashable {
  /// The salt used for the admin signature.
  public let salt: String

  /// The hex string of the admin signature (the wire response's `signature.data`).
  public let signature: String

  /// The expiration timestamp (ISO-8601 or unix timestamp string).
  public let expiresAt: String

  public init(salt: String, signature: String, expiresAt: String) {
    self.salt = salt
    self.signature = signature
    self.expiresAt = expiresAt
  }
}
