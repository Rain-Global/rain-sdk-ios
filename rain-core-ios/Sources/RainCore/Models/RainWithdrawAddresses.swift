import Foundation
import Web3

/// The addresses a collateral withdrawal needs. Field names follow the Rain API's collateral
/// contract object (`GET /v1/issuing/users/{userId}/contracts`), which is where a host gets them.
public struct RainWithdrawAddresses: Sendable, Hashable {
  /// The collateral proxy contract holding the asset.
  public let proxyAddress: String

  /// The collateral controller contract the withdrawal is executed against.
  public let controllerAddress: String

  /// The token being withdrawn.
  public let tokenAddress: String

  /// The address receiving the tokens.
  public let recipientAddress: String

  /// The contract's `depositAddress` from the same Rain API response. Required on Solana, where the
  /// SDK checks it against the collateral program the RPC node reports; unused on EVM chains.
  public let depositAddress: String?

  public init(
    proxyAddress: String,
    controllerAddress: String,
    tokenAddress: String,
    recipientAddress: String,
    depositAddress: String? = nil
  ) {
    self.proxyAddress = proxyAddress
    self.controllerAddress = controllerAddress
    self.tokenAddress = tokenAddress
    self.recipientAddress = recipientAddress
    self.depositAddress = depositAddress
  }

  /// Returns a copy with every EVM address checksummed, throwing if any is not a valid EVM address.
  /// `depositAddress` is returned unchanged.
  public func validated() throws -> RainWithdrawAddresses {
    RainWithdrawAddresses(
      proxyAddress: try Self.checksummed(proxyAddress, label: "proxyAddress"),
      controllerAddress: try Self.checksummed(controllerAddress, label: "controllerAddress"),
      tokenAddress: try Self.checksummed(tokenAddress, label: "tokenAddress"),
      recipientAddress: try Self.checksummed(recipientAddress, label: "recipientAddress"),
      depositAddress: depositAddress
    )
  }

  /// Checksums one address, throwing `invalidConfig` when it is not a valid EVM address.
  internal static func checksummed(_ address: String, label: String) throws -> String {
    guard let parsed = EthereumAddress.parse(address) else {
      throw RainError.invalidConfig(details: "Invalid \(label) format: \(address)")
    }
    return parsed.hex(eip55: true)
  }
}
