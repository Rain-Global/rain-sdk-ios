import Foundation

/// Metadata for a chain's native currency (e.g. ETH on Ethereum, AVAX on Avalanche).
///
/// Static per-chain reference data, looked up by chain ID in the token registry.
public struct NativeCurrency: Sendable, Equatable, Hashable {
  /// Currency symbol (e.g. "ETH", "AVAX", "POL").
  public let symbol: String

  /// Human-readable name (e.g. "Ether", "Avalanche").
  public let name: String

  /// Number of decimal places. Effectively always 18 for EVM native currencies.
  public let decimals: Int

  public init(symbol: String, name: String, decimals: Int = 18) {
    self.symbol = symbol
    self.name = name
    self.decimals = decimals
  }
}
