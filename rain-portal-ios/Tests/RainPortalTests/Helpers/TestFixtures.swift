import Foundation
import PortalSwift
@_spi(RainAdapter) @testable import RainCore
@testable import RainPortal

// MARK: - Shared test fixtures (duplicated into the portal test target)

enum TestFixtures {
  static let walletAddress = "0x1234567890123456789012345678901234567890"
  static let contractAddress = "0x1234567890123456789012345678901234567890"
  static let proxyAddress = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
  static let recipientAddress = "0xfedcbafedcbafedcbafedcbafedcbafedcbafedc"
  static let tokenAddress = "0x9876543210987654321098765432109876543210"
  static let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

  static let validSaltBase64 = Data(repeating: 0xAA, count: 32).base64EncodedString()
  static let validSignatureHex = "0x" + String(repeating: "01", count: 65)

  /// Rain-issued withdrawal authorization, with a unix-seconds `expiresAt`.
  static func adminSignature(
    salt: String = Data(repeating: 0xAA, count: 32).base64EncodedString(),
    signature: String = "0x" + String(repeating: "01", count: 65),
    expiresAt: String = "1735689600"
  ) -> RainAdminSignature {
    RainAdminSignature(salt: salt, signature: signature, expiresAt: expiresAt)
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
//
// The monolith's `RainSDKManager()` + `initialize*`/`setWalletProvider` lifecycle is gone. A
// `RainSdkManager` (the concrete `RainClient`) is now always constructed already bound to a
// resolved `WalletProvider`. `portalManager` wires the `PortalWalletProviderAdapter` directly,
// the same seam `PortalProvider.create(context:)` uses.

enum TestManagers {
  /// Returns a manager backed by a Portal mock and a mock transaction builder.
  static func portalManager(
    portal: MockPortal? = nil,
    builder: MockTransactionBuilderService? = nil,
    configs: [NetworkConfig] = TestFixtures.configs(),
    authPullChainIds: Set<Int> = [],
    authPullTokenAddresses: [Int: String] = [:]
  ) -> (RainSdkManager, MockPortal, MockTransactionBuilderService) {
    let resolvedPortal = portal ?? {
      let p = MockPortal()
      p.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
      return p
    }()
    let resolvedBuilder = builder ?? MockTransactionBuilderService(networkConfigs: configs)
    let tokenStore = TokenMetadataStore(chainReader: EVMChainReader(networkConfigs: configs))
    let adapter = PortalWalletProviderAdapter(
      portal: resolvedPortal,
      tokenStore: tokenStore
    )
    let manager = RainSdkManager(
      walletProvider: adapter,
      networkConfigs: configs,
      transactionBuilder: resolvedBuilder,
      tokenStore: tokenStore,
      providerId: .portal,
      capabilities: [.export, .recovery],
      authPullChainIds: authPullChainIds,
      authPullTokenAddresses: authPullTokenAddresses
    )
    return (manager, resolvedPortal, resolvedBuilder)
  }

  /// Returns a manager bound to a `StubWalletProvider`.
  static func stubProviderManager(
    configs: [NetworkConfig] = TestFixtures.configs()
  ) async throws -> (RainSdkManager, StubWalletProvider) {
    let stub = StubWalletProvider()
    let builder = MockTransactionBuilderService(networkConfigs: configs)
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

  /// Builds a `RainSdk` for wallet-agnostic building tests (`buildTransactionParameters` /
  /// `composeTransactionParameters`). Registers a `PortalProvider` so `build()` passes; the
  /// provider is never resolved, so no real Portal instance is created.
  static func rainSdk(configs: [NetworkConfig] = TestFixtures.configs()) throws -> RainSdk {
    try RainSdk.builder()
      .rpcEndpoints(configs)
      .register(PortalProvider(PortalConfig(sessionToken: "test-token")))
      .build()
  }
}

