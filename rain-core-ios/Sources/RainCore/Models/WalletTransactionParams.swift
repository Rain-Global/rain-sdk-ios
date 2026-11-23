import Foundation

/// Provider-agnostic transaction parameters for sending a transaction.
/// Used by `WalletProvider`; adapters convert to/from provider-specific types (e.g. Portal's `ETHTransactionParam`).
public struct WalletTransactionParams: Sendable {
  public let from: String
  public let to: String
  public let value: String
  public let data: String

  public init(
    from: String,
    to: String,
    value: String,
    data: String
  ) {
    self.from = from
    self.to = to
    self.value = value
    self.data = data
  }
}
