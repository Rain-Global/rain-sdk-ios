import Testing
@testable import RainCore

@Suite("RainChain")
struct RainChainTests {

  @Test("chain IDs are pinned; hosts and the Rain API both switch on them")
  func chainIdsArePinned() {
    #expect(RainChain.avalancheMainnet == 43114)
    #expect(RainChain.avalancheTestnet == 43113)
    #expect(RainChain.solanaMainnet == 900)
    #expect(RainChain.solanaTestnet == 902)
    #expect(RainChain.solanaDevnet == 901)
  }

  @Test("Auth Pull chain IDs are pinned")
  func authPullChainIdsArePinned() {
    #expect(RainChain.baseMainnet == 8453)
    #expect(RainChain.baseSepolia == 84532)
    #expect(RainChain.arbitrumMainnet == 42161)
    #expect(RainChain.arbitrumSepolia == 421614)
  }

  @Test("USDC is registered on every Auth Pull chain, at 6 decimals")
  func authPullUsdcIsRegistered() throws {
    let expected: [Int: String] = [
      RainChain.baseMainnet: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      RainChain.baseSepolia: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      RainChain.arbitrumMainnet: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
      RainChain.arbitrumSepolia: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
    ]

    for (chainId, address) in expected {
      let usdc = try #require(
        TokenRegistry.tokens(for: chainId).first { $0.symbol == "USDC" },
        "no USDC registered on chain \(chainId)"
      )
      #expect(usdc.address == address)
      #expect(usdc.decimals == 6)
    }
  }

  @Test("the Auth Pull testnets report ETH as their gas token")
  func authPullTestnetsHaveNativeCurrency() {
    #expect(TokenRegistry.nativeCurrency(for: RainChain.baseSepolia).symbol == "ETH")
    #expect(TokenRegistry.nativeCurrency(for: RainChain.arbitrumSepolia).symbol == "ETH")
  }

  @Test("Solana routing recognizes the public sentinel IDs")
  func solanaSentinelsRoute() {
    #expect(SolanaChains.isSolana(RainChain.solanaMainnet))
    #expect(SolanaChains.isSolana(RainChain.solanaTestnet))
    #expect(SolanaChains.isSolana(RainChain.solanaDevnet))
    #expect(!SolanaChains.isSolana(RainChain.avalancheMainnet))
  }
}
