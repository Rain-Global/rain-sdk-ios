import Foundation

/// Cross-module surface of the core Solana stack for out-of-core wallet adapters (Privy, Portal).
/// Public for the same reason as `WalletProvider`: adapters ship as separate packages, so
/// `internal` would wall them off. Not API for host apps — they get one from `ProviderContext`.
///
/// Bundles transfer composition (with all preflights and simulation — see
/// ``SolanaTransferComposer``) and balance reads. Signing and broadcasting stay with the
/// adapter, which is the only vendor-specific step. Transaction history is not served here:
/// it always comes from the wallet vendor (Turnkey activities, Privy indexer).
public struct RainSolanaSupport: Sendable {
  private let reader: SolanaChainReader
  private let rpcClient: SolanaRpcClient
  private let composer: SolanaTransferComposer

  /// `session` is injectable for tests.
  public init(networkConfigs: [NetworkConfig], session: URLSession = .shared) {
    let rpcClient = SolanaRpcClient(
      jsonRpcClient: JsonRpcClient(session: session),
      networkConfigs: networkConfigs
    )
    self.rpcClient = rpcClient
    self.reader = SolanaChainReader(solanaRpcClient: rpcClient)
    self.composer = SolanaTransferComposer(rpcClient: rpcClient)
  }

  public func isSolanaChain(_ chainId: Int) -> Bool {
    SolanaChains.isSolana(chainId)
  }

  // Adapter seams (SPI): Rain's own adapter modules reuse this stack instead of building their
  // own. Reach them via `@_spi(RainAdapter) import RainCore`; not API for host apps.
  @_spi(RainAdapter) public var chainReader: ChainReader { reader }
  @_spi(RainAdapter) public var solanaRpcClient: SolanaRpcClient { rpcClient }
  @_spi(RainAdapter) public var transferComposer: SolanaTransferComposer { composer }

  // MARK: - Transfers

  /// See ``SolanaTransferComposer/composeNative(chainId:from:to:amount:)``.
  public func composeNativeTransfer(
    chainId: Int,
    from fromAddress: String,
    to toAddress: String,
    amount: Decimal
  ) async throws -> UnsignedSolanaTransfer {
    try await composer.composeNative(
      chainId: chainId, from: fromAddress, to: toAddress, amount: amount
    )
  }

  /// See ``SolanaTransferComposer/composeSPLToken(chainId:from:mintAddress:to:amount:)``.
  public func composeSPLTransfer(
    chainId: Int,
    from fromAddress: String,
    mintAddress: String,
    to toAddress: String,
    amount: Decimal
  ) async throws -> UnsignedSolanaTransfer {
    try await composer.composeSPLToken(
      chainId: chainId, from: fromAddress, mintAddress: mintAddress, to: toAddress, amount: amount
    )
  }

  // MARK: - Reads

  /// Native SOL or a single SPL mint. `tokenInfo` supplies symbol / name for a mint (SPL mints
  /// carry none on chain) — pass the registered entry, if any.
  public func getBalance(
    chainId: Int,
    walletAddress: String,
    token: Token = .native,
    tokenInfo: TokenInfo? = nil
  ) async throws -> Balance {
    try await reader.getBalance(
      chainId: chainId,
      walletAddress: walletAddress,
      token: token,
      tokenInfo: tokenInfo
    )
  }

  /// Native SOL plus every SPL token the wallet holds, discovered from the chain.
  public func getBalances(
    chainId: Int,
    walletAddress: String,
    tokens: [TokenInfo] = []
  ) async throws -> [Balance] {
    try await reader.getBalances(chainId: chainId, walletAddress: walletAddress, tokens: tokens)
  }

  /// Recent blockhash for an outgoing transfer. Expires in roughly a minute, so fetch per send.
  public func latestBlockhash(chainId: Int) async throws -> String {
    try await rpcClient.getLatestBlockhash(chainId: chainId)
  }
}

/// Previous name of ``RainSolanaSupport``, kept so adapters compiled against it still build.
@available(*, deprecated, renamed: "RainSolanaSupport")
public typealias RainSolanaChainReader = RainSolanaSupport
