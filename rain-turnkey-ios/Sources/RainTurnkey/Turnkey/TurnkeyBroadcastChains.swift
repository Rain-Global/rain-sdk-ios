import Foundation
@_spi(RainAdapter) import RainCore

/// The chains Turnkey's managed transaction path can broadcast (and gas-sponsor) on.
///
/// The Rain SDK's only send path on Turnkey is `ethSendTransaction` / `solSendTransaction`,
/// which exist solely on Turnkey's managed-broadcast networks — there is no self-broadcast
/// fallback (v0 decision). A send on any other chain would fail opaquely deep in the vendor
/// call, so `requireSendSupport` refuses it up front with `RainError.chainNotSupported`.
///
/// Reads (balances, history, fee estimation) are deliberately NOT gated here; they need an RPC
/// endpoint registered for the chain (some balances also come from Turnkey's own indexer).
/// Avalanche, for example, is read-only but fully readable.
///
/// Source of truth: Turnkey's transaction-management broadcasting documentation
/// (https://docs.turnkey.com/features/transaction-management/broadcasting). When Turnkey adds a
/// network, extend this list and mirror the change in rain-sdk-android.
///
/// This list is the VENDOR's capability, not Rain's product offering — those are different
/// questions. Rain's supported chains and tokens live at https://docs.rain.xyz; a send actually
/// works only for chains in BOTH lists that also have an RPC endpoint registered. Rain chains
/// outside this list (Avalanche, Celo, ZKsync, Plasma, Ink) are read-only through this provider
/// in v0.
internal enum TurnkeyBroadcastChains {

  /// Chains for which the Turnkey `get-balances` API returns data. On any other chain, balance
  /// reads fall through to `ChainReader`.
  /// Source: https://docs.turnkey.com/api-reference/queries/get-balances
  static let balanceApiChainIds: Set<Int> = [
    1,        // Ethereum Mainnet
    11155111, // Sepolia
    8453,     // Base Mainnet
    84532,    // Base Sepolia
    137,      // Polygon Mainnet
    80002,    // Polygon Amoy
  ]

  /// EVM chains with Turnkey-managed broadcast, mainnets and their test networks.
  private static let evmChainIds: Set<Int> = [
    1,        // Ethereum
    11155111, // Ethereum Sepolia
    10,       // Optimism
    11155420, // Optimism Sepolia
    56,       // BNB Smart Chain
    97,       // BNB testnet
    137,      // Polygon
    80002,    // Polygon Amoy
    143,      // Monad (sponsored sends leaving a delegated account under 10 MON revert; see docs)
    10143,    // Monad testnet
    4217,     // Tempo
    42431,    // Tempo Moderato (testnet)
    4663,     // Robinhood Chain
    46630,    // Robinhood Chain testnet
    8453,     // Base
    84532,    // Base Sepolia
    42161,    // Arbitrum One
    421614,   // Arbitrum Sepolia
  ]

  /// Turnkey broadcasts Solana on mainnet and devnet only — not the testnet cluster.
  private static let solanaChainIds: Set<Int> = [
    RainChain.solanaMainnet,
    RainChain.solanaDevnet,
  ]

  static func supportsSend(chainId: Int) -> Bool {
    RainChain.isSolana(chainId) ? solanaChainIds.contains(chainId) : evmChainIds.contains(chainId)
  }

  /// Throws `RainError.chainNotSupported` when `chainId` has no Turnkey-managed broadcast.
  /// Call at the top of every send entry point, before any wallet or network work.
  static func requireSendSupport(chainId: Int) throws {
    guard supportsSend(chainId: chainId) else {
      throw RainError.chainNotSupported(
        chainId: chainId,
        details: "Turnkey-managed broadcast does not cover this chain; this wallet can read "
          + "balances and history on it, but cannot send. See "
          + "docs.turnkey.com/features/transaction-management/broadcasting for covered networks."
      )
    }
  }
}
