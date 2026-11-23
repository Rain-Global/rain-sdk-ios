import Foundation
import RainCore

/// The network the demo app operates on, selected via the dropdown on the home screen.
/// The SDK is initialized with every entry's RPC endpoint at once (see `networkConfigs`), so
/// switching chains needs no re-init.
enum WalletChain: String, CaseIterable, Identifiable {
  case avalancheFuji
  case baseSepolia
  case arbitrumSepolia
  case baseMainnet
  case arbitrumMainnet
  case solanaDevnet

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .avalancheFuji: return "EVM · Avalanche Fuji"
    case .baseSepolia: return "EVM · Base Sepolia"
    case .arbitrumSepolia: return "EVM · Arbitrum Sepolia"
    case .baseMainnet: return "EVM · Base"
    case .arbitrumMainnet: return "EVM · Arbitrum"
    case .solanaDevnet: return "Solana · Devnet"
    }
  }

  var chainId: Int {
    switch self {
    case .avalancheFuji: return RainChain.avalancheTestnet
    case .baseSepolia: return RainChain.baseSepolia
    case .arbitrumSepolia: return RainChain.arbitrumSepolia
    case .baseMainnet: return RainChain.baseMainnet
    case .arbitrumMainnet: return RainChain.arbitrumMainnet
    case .solanaDevnet: return RainChain.solanaDevnet // 901, Rain's Solana devnet chain ID
    }
  }

  var rpcUrl: String {
    switch self {
    case .avalancheFuji: return "https://api.avax-test.network/ext/bc/C/rpc"
    case .baseSepolia: return "https://base-sepolia-rpc.publicnode.com"
    case .arbitrumSepolia: return "https://sepolia-rollup.arbitrum.io/rpc"
    case .baseMainnet: return "https://mainnet.base.org"
    case .arbitrumMainnet: return "https://arb1.arbitrum.io/rpc"
    case .solanaDevnet: return "https://api.devnet.solana.com"
    }
  }

  var nativeSymbol: String {
    switch self {
    case .avalancheFuji: return "AVAX"
    case .baseSepolia, .arbitrumSepolia, .baseMainnet, .arbitrumMainnet: return "ETH"
    case .solanaDevnet: return "SOL"
    }
  }

  var isSolana: Bool { self == .solanaDevnet }

  /// What this chain calls a fungible token — used for labels on the send/balances screens.
  var tokenStandard: String { isSolana ? "SPL" : "ERC-20" }

  /// What the token-address field holds on this chain: a contract on EVM, a mint on Solana.
  var tokenAddressLabel: String { isSolana ? "Token Mint Address" : "Token Contract Address" }

  /// Token the demo pre-fills for this chain, so a tester doesn't have to find one first: USDC on
  /// each testnet, and the devnet USDC mint on Solana. Clear the field to use a different one.
  var defaultTokenAddress: String {
    switch self {
    case .avalancheFuji: return "0x5425890298aed601595a70AB815c96711a31Bc65" // Fuji USDC
    case .baseSepolia: return "0x036CbD53842c5426634e7929541eC2318f3dCF7e"   // Base Sepolia USDC
    case .arbitrumSepolia: return "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" // Arbitrum Sepolia USDC
    case .baseMainnet: return "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"   // Base USDC
    case .arbitrumMainnet: return "0xaf88d065e77c8cC2239327C5EDb3A432268e5831" // Arbitrum USDC
    case .solanaDevnet: return "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU" // Devnet USDC mint
    }
  }

  /// A sample recipient pre-filled on the send screen. Blank on Solana on purpose: an SPL
  /// transfer creates the recipient's token account at the sender's expense, so the address is
  /// worth typing deliberately rather than defaulting.
  var defaultRecipient: String {
    isSolana ? "" : "0x3cA8ac240F6ebeA8684b3E629A8e8C1f0E3bC0Ff"
  }

  /// Naming for ``defaultTokenAddress``, registered with the SDK at init. An SPL mint carries no
  /// on-chain symbol (and Turnkey's asset index skips devnet), so without this a discovered
  /// holding shows only its mint address.
  var defaultTokenInfo: TokenInfo {
    TokenInfo(
      chainId: chainId,
      address: defaultTokenAddress,
      symbol: "USDC",
      decimals: 6,
      name: isSolana ? "USD Coin (devnet)" : "USDC"
    )
  }

  /// Whether Rain's Auth Pull runs on this chain *in the environment this build is configured for*.
  /// Read from the SDK's per-environment sets rather than restated here. Approvals are ERC-20, so
  /// Solana is out either way.
  ///
  /// This is the picker's answer, and it has to exist before any SDK does — the chain list is built
  /// at startup, the SDK only after the user supplies credentials. Once a client exists it is the
  /// stricter authority (`RainClient.authPullChainIds`), since a host's `RainAuthPullConfig` and
  /// RPC map can be narrower than the environment; the Auth Pull screen gates on that instead.
  var supportsAuthPull: Bool {
    SampleEnvironment.authPullChains.contains(chainId)
  }

  /// An Auth Pull chain belonging to the environment this build is *not* configured for.
  ///
  /// Hidden from the picker: an approval there is rejected by the SDK, and on mainnet a send would
  /// move real funds.
  var isForeignAuthPullChain: Bool {
    let everyAuthPullChain = RainAuthPullChains.sandbox.union(RainAuthPullChains.production)
    return everyAuthPullChain.contains(chainId) && !supportsAuthPull
  }

  /// Block-explorer name, e.g. for a "View on Snowtrace" label.
  var explorerName: String {
    switch self {
    case .avalancheFuji: return "Snowtrace"
    case .baseSepolia, .baseMainnet: return "Basescan"
    case .arbitrumSepolia, .arbitrumMainnet: return "Arbiscan"
    case .solanaDevnet: return "Solana Explorer"
    }
  }

  private var explorerBase: String {
    switch self {
    case .avalancheFuji: return "https://testnet.snowtrace.io"
    case .baseSepolia: return "https://sepolia.basescan.org"
    case .arbitrumSepolia: return "https://sepolia.arbiscan.io"
    case .baseMainnet: return "https://basescan.org"
    case .arbitrumMainnet: return "https://arbiscan.io"
    case .solanaDevnet: return "https://explorer.solana.com"
    }
  }

  private var explorerSuffix: String {
    isSolana ? "?cluster=devnet" : ""
  }

  func explorerTxURL(hash: String) -> URL? {
    URL(string: "\(explorerBase)/tx/\(hash)\(explorerSuffix)")
  }

  func explorerAddressURL(address: String) -> URL? {
    URL(string: "\(explorerBase)/address/\(address)\(explorerSuffix)")
  }

  /// True when a Rain collateral contract on `contractChainId` belongs to this wallet. Solana
  /// matches its exact cluster; EVM accepts any EVM contract because Rain deploys the user's
  /// collateral on one EVM chain (Base Sepolia) regardless of which EVM chain is selected.
  func ownsCollateralContract(chainId contractChainId: Int) -> Bool {
    isSolana ? contractChainId == chainId : !Self.solanaChainIds.contains(contractChainId)
  }

  /// Light client-side address sanity check (the SDK validates authoritatively).
  func isValidAddress(_ address: String) -> Bool {
    guard !address.isEmpty else { return false }
    if isSolana {
      return (32...44).contains(address.count)
        && address.allSatisfy { Self.base58Alphabet.contains($0) }
    }
    return address.hasPrefix("0x")
      && address.count == 42
      && address.dropFirst(2).allSatisfy { $0.isHexDigit }
  }

  /// The chains this build offers, which is every case minus the other environment's Auth Pull
  /// chains. Use this for anything user-facing; ``allCases`` stays the lookup table, so a contract
  /// on a hidden chain still resolves a name.
  static var selectable: [WalletChain] {
    allCases.filter { !$0.isForeignAuthPullChain }
  }

  /// The first Auth Pull chain this build offers, for seeding the Auth Pull form before the user
  /// has picked a chain.
  static var firstAuthPullChain: WalletChain? {
    selectable.first { $0.supportsAuthPull }
  }

  /// Every selectable chain's NetworkConfig, for initializing the SDK with all chains at once.
  static var networkConfigs: [NetworkConfig] {
    selectable.map {
      NetworkConfig(chainId: $0.chainId, rpcUrl: $0.rpcUrl, networkName: $0.displayName)
    }
  }

  /// EVM-only configs, for Portal (whose adapter holds no Solana account).
  static var evmNetworkConfigs: [NetworkConfig] {
    networkConfigs.filter { !RainChain.isSolana($0.chainId) }
  }

  static func from(chainId: Int) -> WalletChain? {
    allCases.first { $0.chainId == chainId }
  }

  /// Rain's Solana chain IDs, for classifying a collateral contract's chain family.
  static let solanaChainIds: Set<Int> = [
    RainChain.solanaMainnet, RainChain.solanaTestnet, RainChain.solanaDevnet
  ]

  private static let base58Alphabet =
    Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
}
