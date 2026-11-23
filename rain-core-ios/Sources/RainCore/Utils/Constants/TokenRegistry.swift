import Foundation

/// Static registry of ERC-20 tokens the SDK knows how to read balances for.
///
/// Used by `ChainReader` to batch-fetch balances on chains that aren't covered by a
/// wallet provider's native balance API (e.g. chains outside Turnkey's allowlist).
///
/// **Scope**
/// - ERC-20 entries only. Solana SPL entries from the client's list are intentionally omitted —
///   SPL balances are discovered on-chain by `SolanaChainReader`, and hosts supply SPL naming
///   via registered token info (mints carry no on-chain symbol).
/// - Stellar USDC is intentionally omitted (non-EVM; would require a separate Horizon client).
///
/// **Maintenance**
/// This list lives in-tree, so the SDK owns updates. When tokens are added, removed,
/// or migrated, edit this file and ship a new SDK release. Decimals are best-effort
/// based on the canonical issuer's documentation at time of authoring.
///
/// **Multicall3 status**
/// Chains with a known Multicall3 deployment are listed in `Multicall3.deployments` — those use
/// the batched `aggregate3` path. Any chain not in that map uses the parallel `eth_call`
/// fallback. The two lists (this registry and the deployment map) must stay in sync;
/// `Multicall3Tests` enforces that.
internal enum TokenRegistry {
  /// Tokens grouped by EIP-155 chain ID.
  static let tokensByChainId: [Int: [TokenInfo]] = [
    // Ethereum
    1: [
      TokenInfo(chainId: 1, address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 1, address: "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8", symbol: "PYUSD", decimals: 6, name: "PayPal USD"),
      TokenInfo(chainId: 1, address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", symbol: "USDT", decimals: 6, name: "Tether USD"),
      TokenInfo(chainId: 1, address: "0xfdcC3dd6671eaB0709A4C0f3F53De9a333d80798", symbol: "SBC", decimals: 18, name: "SBC"),
      TokenInfo(chainId: 1, address: "0x4F604735c1cF31399C6E711D5962b2B3E0225AD3", symbol: "USDGLO", decimals: 18, name: "Glo Dollar"),
      TokenInfo(chainId: 1, address: "0xC9E3df3D230980B45adC623C81C3DF4A73a5350f", symbol: "USD+", decimals: 6, name: "USD+"),
      TokenInfo(chainId: 1, address: "0xe343167631d89B6Ffc58B88d6b7fB0228795491D", symbol: "USDG", decimals: 6, name: "Global Dollar"),
    ],
    // Optimism
    10: [
      TokenInfo(chainId: 10, address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 10, address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", symbol: "DAI", decimals: 18, name: "Dai Stablecoin"),
      TokenInfo(chainId: 10, address: "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58", symbol: "USDT", decimals: 6, name: "Tether USD"),
      TokenInfo(chainId: 10, address: "0xf9FB20B8E097904f0aB7d12e9DbeE88f2dcd0F16", symbol: "SBC", decimals: 18, name: "SBC"),
      TokenInfo(chainId: 10, address: "0x4F604735c1cF31399C6E711D5962b2B3E0225AD3", symbol: "USDGLO", decimals: 18, name: "Glo Dollar"),
    ],
    // BNB Chain
    56: [
      TokenInfo(chainId: 56, address: "0x8AC76a51cc950d9822D68b83Fe1AD97B32Cd580d", symbol: "USDC", decimals: 18, name: "USDC"),
      TokenInfo(chainId: 56, address: "0x55d398326f99059fF775485246999027B3197955", symbol: "USDT", decimals: 18, name: "Tether USD"),
    ],
    // Polygon
    137: [
      TokenInfo(chainId: 137, address: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 137, address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", symbol: "USDC.e", decimals: 6, name: "Bridged USDC"),
      TokenInfo(chainId: 137, address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", symbol: "USDT", decimals: 6, name: "Tether USD"),
      TokenInfo(chainId: 137, address: "0xfdcC3dd6671eaB0709A4C0f3F53De9a333d80798", symbol: "SBC", decimals: 18, name: "SBC"),
      TokenInfo(chainId: 137, address: "0x4F604735c1cF31399C6E711D5962b2B3E0225AD3", symbol: "USDGLO", decimals: 18, name: "Glo Dollar"),
      TokenInfo(chainId: 137, address: "0x949E7b96C3946A0A035d33094FcB58418d50c505", symbol: "rUSD", decimals: 18, name: "Rain USD"),
    ],
    // zkSync Era
    324: [
      TokenInfo(chainId: 324, address: "0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4", symbol: "USDC", decimals: 6, name: "USDC"),
    ],
    // Base
    8453: [
      TokenInfo(chainId: 8453, address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 8453, address: "0xFa2ACD0861Bd3219D5764d349D3a970AE8321620", symbol: "DKUSD", decimals: 6, name: "DKUSD"),
      TokenInfo(chainId: 8453, address: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb", symbol: "DAI", decimals: 18, name: "Dai Stablecoin"),
      TokenInfo(chainId: 8453, address: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", symbol: "USDT", decimals: 6, name: "Tether USD"),
      TokenInfo(chainId: 8453, address: "0xfdcC3dd6671eaB0709A4C0f3F53De9a333d80798", symbol: "SBC", decimals: 18, name: "SBC"),
      TokenInfo(chainId: 8453, address: "0xd899C2254C1F4B11FfF038571D6cb02aB8860eC8", symbol: "rUSD", decimals: 6, name: "Rain USD"),
      TokenInfo(chainId: 8453, address: "0x4F604735c1cF31399C6E711D5962b2B3E0225AD3", symbol: "USDGLO", decimals: 18, name: "Glo Dollar"),
    ],
    // Plasma
    9745: [
      TokenInfo(chainId: 9745, address: "0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb", symbol: "USDT0", decimals: 6, name: "USDT0"),
    ],
    // Monad
    143: [
      TokenInfo(chainId: 143, address: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", symbol: "USDC", decimals: 6, name: "USDC"),
    ],
    // Arbitrum
    42161: [
      TokenInfo(chainId: 42161, address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 42161, address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", symbol: "DAI", decimals: 18, name: "Dai Stablecoin"),
      TokenInfo(chainId: 42161, address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", symbol: "USDT", decimals: 6, name: "Tether USD"),
      TokenInfo(chainId: 42161, address: "0xfdcC3dd6671eaB0709A4C0f3F53De9a333d80798", symbol: "SBC", decimals: 18, name: "SBC"),
      TokenInfo(chainId: 42161, address: "0x4F604735c1cF31399C6E711D5962b2B3E0225AD3", symbol: "USDGLO", decimals: 18, name: "Glo Dollar"),
      TokenInfo(chainId: 42161, address: "0xC9E3df3D230980B45adC623C81C3DF4A73a5350f", symbol: "USD+", decimals: 6, name: "USD+"),
    ],
    // Celo
    42220: [
      TokenInfo(chainId: 42220, address: "0xceba9300f2b948710d2653dd7b07f33a8b32118c", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 42220, address: "0x48065fbBE25f71C9282DDF5e1CD6D6A887483D5e", symbol: "USDT", decimals: 6, name: "Tether USD"),
    ],
    // Avalanche
    43114: [
      TokenInfo(chainId: 43114, address: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 43114, address: "0xd586E7F844cEa2F87f50152665BCbc2C279D8d70", symbol: "DAI", decimals: 18, name: "Dai Stablecoin"),
      TokenInfo(chainId: 43114, address: "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7", symbol: "USDT", decimals: 6, name: "Tether USD"),
      TokenInfo(chainId: 43114, address: "0xf9FB20B8E097904f0aB7d12e9DbeE88f2dcd0F16", symbol: "SBC", decimals: 18, name: "SBC"),
      TokenInfo(chainId: 43114, address: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", symbol: "WAVAX", decimals: 18, name: "Wrapped AVAX"),
      TokenInfo(chainId: 43114, address: "0x5E817F2AbCCB9095585D26c2a3ce234a440574Fc", symbol: "FRNT", decimals: 6, name: "FRNT"),
      TokenInfo(chainId: 43114, address: "0xFd56187DCe1A7c5Ad5aaE9cA3A8827267e69E58a", symbol: "TenantToken", decimals: 18, name: "TenantToken (Raindrop)"),
    ],
    // Base Sepolia — Auth Pull sandbox
    84532: [
      TokenInfo(chainId: 84532, address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", symbol: "USDC", decimals: 6, name: "USDC"),
    ],
    // Arbitrum Sepolia — Auth Pull sandbox
    421614: [
      TokenInfo(chainId: 421614, address: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", symbol: "USDC", decimals: 6, name: "USDC"),
    ],
    // Ink
    57073: [
      TokenInfo(chainId: 57073, address: "0x2D270e6886d130D724215A266106e6832161EAEd", symbol: "USDC", decimals: 6, name: "USDC"),
      TokenInfo(chainId: 57073, address: "0xe343167631d89B6Ffc58B88d6b7fB0228795491D", symbol: "USDG", decimals: 6, name: "Global Dollar"),
    ],
  ]

  /// Returns the configured tokens for a chain, or an empty array if none are known.
  static func tokens(for chainId: Int) -> [TokenInfo] {
    tokensByChainId[chainId] ?? []
  }

  /// Native currency metadata per EIP-155 chain ID.
  ///
  /// Static reference data (the chain's gas token), best-effort like the token list above.
  /// Every chain here is EVM, so decimals default to 18.
  static let nativeCurrencyByChainId: [Int: NativeCurrency] = [
    1: NativeCurrency(symbol: "ETH", name: "Ether"),
    10: NativeCurrency(symbol: "ETH", name: "Ether"),
    56: NativeCurrency(symbol: "BNB", name: "BNB"),
    137: NativeCurrency(symbol: "POL", name: "Polygon Ecosystem Token"),
    143: NativeCurrency(symbol: "MON", name: "Monad"),
    324: NativeCurrency(symbol: "ETH", name: "Ether"),
    8453: NativeCurrency(symbol: "ETH", name: "Ether"),
    9745: NativeCurrency(symbol: "XPL", name: "Plasma"),
    42161: NativeCurrency(symbol: "ETH", name: "Ether"),
    42220: NativeCurrency(symbol: "CELO", name: "Celo"),
    43114: NativeCurrency(symbol: "AVAX", name: "Avalanche"),
    57073: NativeCurrency(symbol: "ETH", name: "Ether"),
    84532: NativeCurrency(symbol: "ETH", name: "Ether"),
    421614: NativeCurrency(symbol: "ETH", name: "Ether"),
    // Solana clusters (Rain chain IDs — see RainChain). SOL has 9 decimals, not 18.
    RainChain.solanaMainnet: NativeCurrency(symbol: "SOL", name: "Solana", decimals: 9),
    RainChain.solanaTestnet: NativeCurrency(symbol: "SOL", name: "Solana", decimals: 9),
    RainChain.solanaDevnet: NativeCurrency(symbol: "SOL", name: "Solana", decimals: 9),
  ]

  /// Native currency for a chain. Falls back to an 18-decimal ETH-like default for chains
  /// not explicitly listed — every chain the SDK targets today is EVM.
  static func nativeCurrency(for chainId: Int) -> NativeCurrency {
    nativeCurrencyByChainId[chainId] ?? NativeCurrency(symbol: "ETH", name: "Ether")
  }
}
