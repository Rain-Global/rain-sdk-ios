import Foundation
@_spi(RainAdapter) @testable import RainCore

// MARK: - Shared test fixtures

enum TestFixtures {
  static let walletAddress = "0x1234567890123456789012345678901234567890"
  static let contractAddress = "0x1234567890123456789012345678901234567890"
  static let proxyAddress = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
  static let recipientAddress = "0xfedcbafedcbafedcbafedcbafedcbafedcbafedc"
  static let tokenAddress = "0x9876543210987654321098765432109876543210"
  static let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  /// Canonical Base Sepolia USDC — the only token an Auth Pull approval may target there.
  static let authPullUsdcAddress = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  /// The user's collateral contract, the spender an Auth Pull approval names.
  static let authPullSpender = "0x5a6E6b0d5Ea051CfFF9b3dcC2Aa8Dac226458f29"

  /// The trusted token contract per Auth Pull chain, for the chains a test drives.
  static func authPullTokens(for chainIds: Set<Int>) -> [Int: String] {
    var tokens: [Int: String] = [:]
    for chainId in chainIds {
      switch chainId {
      case RainChain.baseSepolia: tokens[chainId] = authPullUsdcAddress
      case RainChain.arbitrumSepolia: tokens[chainId] = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
      case RainChain.baseMainnet: tokens[chainId] = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      case RainChain.arbitrumMainnet: tokens[chainId] = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
      default: tokens[chainId] = authPullUsdcAddress
      }
    }
    return tokens
  }

  /// 32-byte salt encoded as base64. Used by withdrawCollateral / estimateWithdrawalFee.
  static let validSaltBase64 = Data(repeating: 0xAA, count: 32).base64EncodedString()

  /// 65-byte signature encoded as hex with `0x` prefix.
  static let validSignatureHex = "0x" + String(repeating: "01", count: 65)

  /// Rain-issued withdrawal authorization, with a unix-seconds `expiresAt`.
  static func adminSignature(expiresAt: String = "1735689600") -> RainAdminSignature {
    RainAdminSignature(
      salt: validSaltBase64,
      signature: validSignatureHex,
      expiresAt: expiresAt
    )
  }

  static var defaultWithdrawAddresses: RainWithdrawAddresses {
    RainWithdrawAddresses(
      proxyAddress: proxyAddress,
      controllerAddress: contractAddress,
      tokenAddress: tokenAddress,
      recipientAddress: recipientAddress
    )
  }

  static func configs(
    chainId: Int = 1,
    rpcUrl: String = "https://mainnet.infura.io/v3/test"
  ) -> [NetworkConfig] {
    [NetworkConfig.testConfig(chainId: chainId, rpcUrl: rpcUrl)]
  }
}

// MARK: - Manager factories
//
// The monolith's `RainSDKManager()` + `initialize*`/`setWalletProvider` lifecycle no longer
// exists. A `RainSdkManager` (the concrete `RainClient`) is now always constructed already bound
// to a resolved `WalletProvider`. These factories build a manager directly around a stub —
// the same seam the registry uses when resolving a provider.

enum TestManagers {
  /// Returns a manager bound to a `StubWalletProvider` with the chain reader and transaction
  /// builder mocked out — the seam the approval flow needs, since it both encodes calldata and
  /// reads allowances off chain.
  static func approvalManager(
    configs: [NetworkConfig] = TestFixtures.configs(
      chainId: RainChain.baseSepolia,
      rpcUrl: "https://sepolia.base.org"
    ),
    registeredTokens: [TokenInfo] = [],
    authPullChainIds: Set<Int> = RainAuthPullChains.sandbox,
    authPullTokenAddresses: [Int: String]? = nil,
    reader: MockChainReader = MockChainReader(),
    approvalConfirmationInterval: Duration = .seconds(1)
  ) -> (RainSdkManager, StubWalletProvider, MockChainReader, MockTransactionBuilderService) {
    let stub = StubWalletProvider()
    let builder = MockTransactionBuilderService(networkConfigs: configs)
    let tokenStore = TokenMetadataStore(chainReader: reader, seedTokens: registeredTokens)
    let manager = RainSdkManager(
      walletProvider: stub,
      networkConfigs: configs,
      transactionBuilder: builder,
      tokenStore: tokenStore,
      providerId: ProviderId("stub"),
      capabilities: [],
      chainReader: reader,
      authPullChainIds: authPullChainIds,
      authPullTokenAddresses: authPullTokenAddresses
        ?? TestFixtures.authPullTokens(for: authPullChainIds),
      approvalConfirmationInterval: approvalConfirmationInterval
    )
    return (manager, stub, reader, builder)
  }

  /// A manager built the way `RainSdk` builds one when no `authPullConfig(_:)` was supplied.
  static func authPullDisabledManager(
    configs: [NetworkConfig] = TestFixtures.configs(
      chainId: RainChain.baseSepolia,
      rpcUrl: "https://sepolia.base.org"
    )
  ) -> RainSdkManager {
    let reader = MockChainReader()
    return RainSdkManager(
      walletProvider: StubWalletProvider(),
      networkConfigs: configs,
      transactionBuilder: MockTransactionBuilderService(networkConfigs: configs),
      tokenStore: TokenMetadataStore(chainReader: reader, seedTokens: []),
      providerId: ProviderId("stub"),
      capabilities: [],
      chainReader: reader
    )
  }

  /// Returns a manager bound to a `StubWalletProvider`. The returned stub is mutable — tests
  /// configure return values on it.
  static func stubProviderManager(
    configs: [NetworkConfig] = TestFixtures.configs()
  ) async throws -> (RainSdkManager, StubWalletProvider) {
    try await stubProviderManager(stub: StubWalletProvider(), configs: configs)
  }

  /// Same manager over a caller-supplied stub (e.g. `FeeEstimatingStubWalletProvider`).
  static func stubProviderManager<Stub: StubWalletProvider>(
    stub: Stub,
    configs: [NetworkConfig] = TestFixtures.configs(),
    builder: MockTransactionBuilderService? = nil
  ) async throws -> (RainSdkManager, Stub) {
    let builder = builder ?? MockTransactionBuilderService(networkConfigs: configs)
    let tokenStore = TokenMetadataStore(chainReader: EVMChainReader(networkConfigs: configs))
    let manager = RainSdkManager(
      walletProvider: stub,
      networkConfigs: configs,
      transactionBuilder: builder,
      tokenStore: tokenStore,
      providerId: ProviderId("stub"),
      capabilities: []
    )
    return (manager, stub)
  }
}
