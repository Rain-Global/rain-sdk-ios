import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore
@testable import RainPortal

/// Validation tests for `PortalProvider` — the Portal-specific init checks that moved out of the
/// monolith's `initializePortal` (empty session token, eip155 RPC config mapping).
@Suite("Portal Provider Validation Tests")
struct PortalProviderValidationTests {

  private func makeContext(configs: [NetworkConfig] = TestFixtures.configs()) -> ProviderContext {
    let reader = EVMChainReader(networkConfigs: configs)
    return ProviderContext(
      rpcEndpoints: Dictionary(uniqueKeysWithValues: configs.map { ($0.chainId, $0.rpcUrl) }),
      networkConfigs: configs,
      tokenStore: TokenMetadataStore(chainReader: reader),
      transactionBuilder: MockTransactionBuilderService(networkConfigs: configs),
      evmChainReader: reader
    )
  }

  @Test("create throws unauthorized for an empty session token")
  func testCreateEmptyToken() async {
    let provider = PortalProvider(PortalConfig(sessionToken: ""))
    await #expect(throws: RainError.unauthorized()) {
      _ = try await provider.create(context: makeContext())
    }
  }

  @Test("portalRpcConfig maps configs to eip155:<chainId> keys")
  func testPortalRpcConfigMapping() {
    let configs = [
      NetworkConfig.testConfig(chainId: 1, rpcUrl: "https://eth.example/rpc"),
      NetworkConfig.testConfig(chainId: 43114, rpcUrl: "https://avax.example/rpc"),
    ]
    let rpcConfig = PortalProvider.portalRpcConfig(from: configs)
    #expect(rpcConfig == [
      "eip155:1": "https://eth.example/rpc",
      "eip155:43114": "https://avax.example/rpc",
    ])
  }

  @Test("descriptor exposes the portal id and export/recovery capabilities")
  func testDescriptorIdentity() {
    let provider = PortalProvider(PortalConfig(sessionToken: "token"))
    #expect(provider.id == .portal)
    #expect(provider.capabilities == [.export, .recovery])
  }
}
