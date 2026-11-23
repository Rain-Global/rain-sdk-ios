import Foundation

/// Per-cluster reference data for Solana, the analogue of `TokenRegistry` for EVM.
///
/// Solana has no EIP-155 integer chain ID, so the SDK keys clusters by Rain's chain IDs
/// (900 mainnet / 901 devnet / 902 testnet, see `RainChain`) and maps them to their CAIP-2
/// (genesis-hash) identifiers — what Turnkey's Solana APIs (`sol_send_transaction`, balances)
/// expect. These IDs are reserved: configuring an EVM chain at 900–902 would be misrouted to
/// the Solana path.
internal enum SolanaChains {
  static let mainnet = RainChain.solanaMainnet
  static let testnet = RainChain.solanaTestnet
  static let devnet = RainChain.solanaDevnet

  /// All Solana sentinel chain IDs. Dispatch keys off this set, never a hardcoded literal.
  static let sentinelChainIds: Set<Int> = [mainnet, testnet, devnet]

  // CAIP-2 references: base58 of each cluster's genesis hash, truncated to 32 chars per the spec.
  private static let caip2ByChainId: [Int: String] = [
    mainnet: "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp",
    testnet: "solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z",
    devnet: "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
  ]

  /// SOL native currency — 9 decimals (vs 18 for EVM), identical across clusters.
  static let nativeCurrency = NativeCurrency(
    symbol: "SOL",
    name: "Solana",
    decimals: SolanaConverter.solDecimals
  )

  static func isSolana(_ chainId: Int) -> Bool {
    caip2ByChainId[chainId] != nil
  }

  /// CAIP-2 identifier for `chainId`, e.g. `solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1`, or
  /// `nil` if `chainId` is not a known Solana cluster.
  static func caip2(for chainId: Int) -> String? {
    caip2ByChainId[chainId]
  }

  /// Reverse lookup: the sentinel chain ID for a CAIP-2 string, or `nil` if unknown.
  static func chainId(forCaip2 caip2: String) -> Int? {
    caip2ByChainId.first(where: { $0.value == caip2 })?.key
  }
}
