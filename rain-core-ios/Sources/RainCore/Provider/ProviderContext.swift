import Foundation

/// Vendor-free infrastructure bundle that `RainSdk` builds once and hands to every adapter's
/// `create(context:)`. Contains no vendor SDK types.
///
/// Public surface (out-of-core adapters): `rpcEndpoints`, `networkConfigs`, `tokenStore`,
/// `solanaSupport`. The transaction builder and EVM chain reader are internal (in-core adapters
/// only) for now.
public final class ProviderContext: @unchecked Sendable {
  /// Chain id → RPC URL, as configured on the builder.
  public let rpcEndpoints: [Int: String]

  /// Full network configs (chain id + RPC URL) the SDK was built with.
  public let networkConfigs: [NetworkConfig]

  /// Shared token metadata store (decimals / symbol / name resolution + cache).
  public let tokenStore: TokenMetadataStore

  /// Solana surface — transfer composition (with preflights), balances and history — shared with
  /// out-of-core adapters.
  public let solanaSupport: RainSolanaSupport

  /// Wallet-agnostic transaction builder. In-core use only (internal); nothing outside core
  /// needs it today.
  internal let transactionBuilder: TransactionBuilderProtocol

  /// EVM chain reader (multicall, RPC reads). SPI: for Rain's own adapter modules
  /// (`@_spi(RainAdapter) import RainCore`), not API for host apps.
  @_spi(RainAdapter) public let evmChainReader: ChainReader

  internal init(
    rpcEndpoints: [Int: String],
    networkConfigs: [NetworkConfig],
    tokenStore: TokenMetadataStore,
    transactionBuilder: TransactionBuilderProtocol,
    evmChainReader: ChainReader
  ) {
    self.rpcEndpoints = rpcEndpoints
    self.networkConfigs = networkConfigs
    self.tokenStore = tokenStore
    self.solanaSupport = RainSolanaSupport(networkConfigs: networkConfigs)
    self.transactionBuilder = transactionBuilder
    self.evmChainReader = evmChainReader
  }
}
