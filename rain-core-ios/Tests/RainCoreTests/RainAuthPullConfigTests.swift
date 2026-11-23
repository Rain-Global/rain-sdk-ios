import Testing
import Foundation
@testable import RainCore

/// Builder-level contract for the trusted Auth Pull configuration: which configurations `build()`
/// accepts, and which chains the resulting SDK will actually approve on.
@Suite("Auth Pull Config Tests")
struct RainAuthPullConfigTests {

  private func configs(_ chainIds: [Int]) -> [NetworkConfig] {
    chainIds.map { NetworkConfig.testConfig(chainId: $0, rpcUrl: "https://rpc.example/\($0)") }
  }

  // MARK: - Accepted configurations

  @Test("a sandbox config with one configured RPC builds")
  func sandboxConfigBuilds() throws {
    _ = try RainSdk.builder()
      .rpcEndpoints(configs([RainChain.baseSepolia]))
      .authPullConfig(.sandbox())
      .build()
  }

  @Test("the canonical token addresses are the ones Rain publishes")
  func canonicalTokenAddresses() {
    let sandbox = RainAuthPullConfig.sandbox()
    #expect(
      sandbox.tokenAddresses[RainChain.baseSepolia] == "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
    )
    #expect(
      sandbox.tokenAddresses[RainChain.arbitrumSepolia] == "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
    )

    let production = RainAuthPullConfig.production()
    #expect(
      production.tokenAddresses[RainChain.baseMainnet] == "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    )
    #expect(
      production.tokenAddresses[RainChain.arbitrumMainnet] == "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
    )
  }

  // MARK: - The resolved chain set

  /// The set the approval guard enforces, which is not the environment's set: a sandbox config
  /// covers two chains, but only the one with an RPC endpoint can carry an approval.
  @Test("the resolved chain set is the config narrowed to chains with an RPC")
  func resolvedSetIsNarrowedByRpc() throws {
    let rain = try RainSdk.builder()
      .rpcEndpoints(configs([RainChain.baseSepolia]))
      .authPullConfig(.sandbox())
      .build()

    #expect(rain.authPullChainIds == [RainChain.baseSepolia])
    // The environment's set is the wider answer, and the one a host must not gate UI on.
    #expect(RainAuthPullChains.sandbox.contains(RainChain.arbitrumSepolia))
  }

  @Test("every configured chain with an RPC is resolved, and nothing else")
  func resolvedSetCoversConfiguredChains() throws {
    let rain = try RainSdk.builder()
      .rpcEndpoints(
        configs([
          RainChain.baseSepolia,
          RainChain.arbitrumSepolia,
          // An unrelated chain must not leak into the Auth Pull set.
          RainChain.avalancheTestnet,
        ])
      )
      .authPullConfig(.sandbox())
      .build()

    #expect(rain.authPullChainIds == [RainChain.baseSepolia, RainChain.arbitrumSepolia])
  }

  /// No `authPullConfig(_:)` means Auth Pull is off, and the set has to say so.
  @Test("an unconfigured SDK resolves no Auth Pull chains")
  func unconfiguredResolvesNothing() throws {
    let rain = try RainSdk.builder()
      .rpcEndpoints(configs([RainChain.baseSepolia]))
      .build()

    #expect(rain.authPullChainIds.isEmpty)
  }

  /// A custom config's own chains are only discoverable through the resolved set — the static
  /// sets cannot know which environment a custom deployment fronts.
  @Test("a custom gateway can enumerate the chains it configured")
  func customGatewayEnumeratesItsChains() throws {
    let rain = try RainSdk.builder()
      .rpcEndpoints(configs([RainChain.baseSepolia, RainChain.arbitrumSepolia]))
      .authPullConfig(
        .custom(
          tokenAddresses: [
            RainChain.arbitrumSepolia: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
          ]
        )
      )
      .build()

    #expect(rain.authPullChainIds == [RainChain.arbitrumSepolia])
  }

  // MARK: - Rejected configurations

  /// The SDK no longer knows a Rain API environment; the config's kind is the environment, and
  /// its chains come from that environment's set — so a well-formed production config builds
  /// without any environment knob.
  @Test("a production config builds on its own")
  func productionConfigBuilds() throws {
    let rain = try RainSdk.builder()
      .rpcEndpoints(configs([RainChain.baseMainnet, RainChain.arbitrumMainnet]))
      .authPullConfig(.production())
      .build()

    #expect(rain.authPullChainIds == [RainChain.baseMainnet, RainChain.arbitrumMainnet])
  }

  @Test("a custom config may mix chains from both environments")
  func customConfigMayMixEnvironments() throws {
    let rain = try RainSdk.builder()
      .rpcEndpoints(configs([RainChain.baseSepolia, RainChain.baseMainnet]))
      .authPullConfig(
        .custom(
          tokenAddresses: [
            RainChain.baseSepolia: TestFixtures.authPullUsdcAddress,
            RainChain.baseMainnet: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
          ]
        )
      )
      .build()

    #expect(rain.authPullChainIds == [RainChain.baseSepolia, RainChain.baseMainnet])
  }

  @Test("an empty token map is rejected")
  func emptyTokenMapRejected() throws {
    #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try RainSdk.builder()
        .rpcEndpoints(configs([RainChain.baseSepolia]))
        .authPullConfig(.custom(tokenAddresses: [:]))
        .build()
    }
  }

  @Test("a malformed or zero token contract is rejected")
  func malformedTokenRejected() throws {
    for token in ["0xnope", "0x0000000000000000000000000000000000000000"] {
      #expect(throws: RainError.invalidConfig(details: "")) {
        _ = try RainSdk.builder()
          .rpcEndpoints(configs([RainChain.baseSepolia]))
            .authPullConfig(
            .custom(
              tokenAddresses: [RainChain.baseSepolia: token]
            )
          )
          .build()
      }
    }
  }

  /// A custom gateway may front either environment, but not a chain Auth Pull does not run on.
  @Test("a chain outside the known Auth Pull sets is rejected")
  func unknownChainRejected() throws {
    #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try RainSdk.builder()
        .rpcEndpoints(configs([RainChain.avalancheTestnet]))
        .authPullConfig(
          .custom(
            tokenAddresses: [RainChain.avalancheTestnet: TestFixtures.authPullUsdcAddress]
          )
        )
        .build()
    }
  }

  /// Without an endpoint there is no chain to read the allowance on or send the approval over, so
  /// the configuration could never do anything.
  @Test("a config whose chains all lack an RPC endpoint is rejected")
  func noRpcForAnyTrustedChainRejected() throws {
    #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try RainSdk.builder()
        .rpcEndpoints(configs([RainChain.avalancheTestnet]))
        .authPullConfig(.sandbox())
        .build()
    }
  }
}
