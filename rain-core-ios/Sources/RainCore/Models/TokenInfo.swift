import Foundation

/// Describes an on-chain ERC-20 token the SDK can read balances for.
///
/// Seeded from the built-in registry and extendable at runtime by host apps via
/// `registerTokens(_:)`.
public struct TokenInfo: Sendable, Equatable, Hashable {
  /// EIP-155 chain ID
  public let chainId: Int

  /// Token contract address
  public let address: String

  /// Token symbol (e.g. "USDC", "DAI"). `nil` when an enriched token's `symbol()` read failed.
  public let symbol: String?

  /// Number of decimal places (e.g. 6 for USDC, 18 for DAI)
  public let decimals: Int

  /// Optional human-readable token name
  public let name: String?

  public init(
    chainId: Int,
    address: String,
    symbol: String?,
    decimals: Int,
    name: String? = nil
  ) {
    self.chainId = chainId
    self.address = address
    self.symbol = symbol
    self.decimals = decimals
    self.name = name
  }
}
