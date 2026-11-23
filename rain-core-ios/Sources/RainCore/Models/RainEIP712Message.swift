import Foundation

/// The EIP-712 message a wallet signs to authorize a withdrawal, plus the salt bound into it.
///
/// The salt is carried as raw bytes — `saltHex` renders the form the EIP-712 domain and the
/// `withdrawAsset` calldata use. Feed the same value straight back into
/// ``RainSdk/buildWithdrawTransactionData(addresses:amount:decimals:executorSignature:walletSalt:walletSignature:)``
/// as `walletSalt`; a re-generated salt would not match the signature.
public struct RainEIP712Message: Sendable, Hashable {
  /// The serialized EIP-712 typed-data JSON to hand to the wallet for signing.
  public let message: String

  /// The 32-byte salt bound into `message`.
  public let salt: Data

  /// `salt` as a `0x`-prefixed lowercase hex string.
  public var saltHex: String { "0x" + salt.toHexString() }

  public init(message: String, salt: Data) {
    self.message = message
    self.salt = salt
  }
}
