import Testing
import Foundation
@testable import RainCore

/// Keeps the Auth Pull chain sets honest against Rain's published support matrix and against the
/// other in-tree lists an approval depends on.
@Suite("Auth Pull Chain Tests")
struct RainAuthPullChainsTests {

  @Test("sandbox is Base Sepolia and Arbitrum Sepolia")
  func sandboxSet() {
    #expect(RainAuthPullChains.sandbox == [84532, 421614])
  }

  @Test("production is Base and Arbitrum mainnet")
  func productionSet() {
    #expect(RainAuthPullChains.production == [8453, 42161])
  }

  @Test("the two environments share no chain")
  func environmentsAreDisjoint() {
    #expect(RainAuthPullChains.sandbox.isDisjoint(with: RainAuthPullChains.production))
  }

  @Test("a config's kind selects its environment's set; custom may front either")
  func kindMapping() {
    #expect(RainAuthPullChains.supported(for: .sandbox) == RainAuthPullChains.sandbox)
    #expect(RainAuthPullChains.supported(for: .production) == RainAuthPullChains.production)
    #expect(RainAuthPullChains.supported(for: .custom)
      == RainAuthPullChains.sandbox.union(RainAuthPullChains.production))
  }

  /// The approval path resolves USDC's decimals from `TokenRegistry`, and refuses to guess. An
  /// Auth Pull chain with no registry entry would force every host to pass `decimals` by hand.
  @Test("every Auth Pull chain ships USDC in the token registry")
  func everyChainHasUsdc() {
    for chainId in RainAuthPullChains.sandbox.union(RainAuthPullChains.production) {
      let usdc = TokenRegistry.tokens(for: chainId).filter { $0.symbol == "USDC" }
      #expect(usdc.count == 1, "chain \(chainId) has \(usdc.count) USDC entries")
      #expect(usdc.first?.decimals == 6)
    }
  }

  /// Allowance reads batch through Multicall3 where it is deployed; all four qualify.
  @Test("every Auth Pull chain has a Multicall3 deployment")
  func everyChainHasMulticall3() {
    for chainId in RainAuthPullChains.sandbox.union(RainAuthPullChains.production) {
      #expect(Multicall3.address(on: chainId) != nil, "chain \(chainId)")
    }
  }

  /// ERC-20 approvals are EVM-only, so no Solana sentinel may leak into either set.
  @Test("no Auth Pull chain is a Solana sentinel")
  func noSolanaSentinels() {
    for chainId in RainAuthPullChains.sandbox.union(RainAuthPullChains.production) {
      #expect(!RainChain.isSolana(chainId), "chain \(chainId)")
    }
  }
}
