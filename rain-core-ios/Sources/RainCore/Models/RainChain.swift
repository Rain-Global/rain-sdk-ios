import Foundation

/// Chain IDs for the networks Rain supports out of the box.
/// Solana has no EIP-155 ID, so the SDK uses Rain's own chain IDs (900 = mainnet-beta,
/// 901 = devnet — the values the Rain issuing API returns in collateral contracts and expects
/// on withdrawal-signature requests). Rain assigns no ID to the testnet cluster; 902 extends
/// the scheme for SDK-internal use only.
public enum RainChain {
  public static let avalancheMainnet = 43114
  public static let avalancheTestnet = 43113

  // Auth Pull chains — Rain pulls authorization amounts from the user's wallet on these.
  // Base / Arbitrum in production, their Sepolia testnets in sandbox.
  public static let baseMainnet = 8453
  public static let baseSepolia = 84532
  public static let arbitrumMainnet = 42161
  public static let arbitrumSepolia = 421614

  public static let solanaMainnet = 900
  public static let solanaTestnet = 902
  public static let solanaDevnet = 901

  /// Public accessors over the `internal` `SolanaChains` so out-of-core adapters (Privy, Portal)
  /// can route Solana chains.
  public static func isSolana(_ chainId: Int) -> Bool { SolanaChains.isSolana(chainId) }
  public static func solanaCaip2(for chainId: Int) -> String? { SolanaChains.caip2(for: chainId) }

  /// SOL native currency (9 decimals). SPI for Rain's own adapter modules.
  @_spi(RainAdapter) public static var solanaNativeCurrency: NativeCurrency { SolanaChains.nativeCurrency }
}
