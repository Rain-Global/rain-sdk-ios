import Testing
import Foundation
import Web3
@testable import PortalSwift
@testable import RainCore
@testable import RainPortal

/// Auth Pull approvals through the Portal adapter: an approval is an ordinary ERC-20 send, so it
/// must reach `eth_sendTransaction` with the token contract as `to` and Portal's simulation
/// behaviour untouched.
@Suite("Portal Token Approval Tests")
struct PortalTokenApprovalTests {

  private let spender = "0x5a6E6b0d5Ea051CfFF9b3dcC2Aa8Dac226458f29"

  /// Auth Pull runs on Base Sepolia in sandbox.
  private var authPullConfigs: [NetworkConfig] {
    TestFixtures.configs(chainId: RainChain.baseSepolia, rpcUrl: "https://sepolia.base.org")
  }

  /// Broadcast routing, not the trusted-target guard: these tests trust the arbitrary token they
  /// send so the assertions are about what reached Portal.
  private func portalManager(
    portal: MockPortal? = nil
  ) -> (RainSdkManager, MockPortal, MockTransactionBuilderService) {
    TestManagers.portalManager(
      portal: portal,
      configs: authPullConfigs,
      authPullChainIds: [RainChain.baseSepolia],
      authPullTokenAddresses: [RainChain.baseSepolia: TestFixtures.tokenAddress]
    )
  }

  @Test("approveTokenAllowance broadcasts through Portal and returns its tx hash")
  func approvalRoutesThroughPortal() async throws {
    let (manager, portal, builder) = portalManager()
    builder.stubbedApproveData = "0x095ea7b3deadbeef"

    let result = try await manager.approveTokenAllowance(
      chainId: RainChain.baseSepolia,
      contractAddress: TestFixtures.tokenAddress,
      spender: spender
    )

    #expect(result.transactionHash == "0x" + String(repeating: "a", count: 64))

    let sent = try #require(portal.requestCalls.last)
    #expect(sent.method == .eth_sendTransaction)

    let params = try #require(sent.params.first as? ETHTransactionParam)
    #expect(params.to == TestFixtures.tokenAddress)
    #expect(params.data == "0x095ea7b3deadbeef")
    #expect(params.from == TestFixtures.walletAddress)

    // Portal simulates before broadcasting; the approval must not skip that.
    #expect(portal.requestCalls.map(\.method).contains(.eth_call))
  }

  @Test("approveTokenAllowance throws walletUnavailable when Portal has no address")
  func approvalWithoutWallet() async throws {
    let mockPortal = MockPortal()
    mockPortal.mockAddresses.removeAll()
    let (manager, _, _) = portalManager(portal: mockPortal)

    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.baseSepolia,
        contractAddress: TestFixtures.tokenAddress,
        spender: spender
      )
    }
  }

  /// Where the Portal environment has Account Abstraction enabled, `eth_sendTransaction` returns a
  /// UserOperation hash that no node can answer for. The adapter must hand back the transaction the
  /// operation was mined in, or every confirmation downstream polls a hash that does not exist.
  @Test("a UserOperation hash resolves to the transaction it was mined in")
  func approvalResolvesUserOperationHash() async throws {
    let minedHash = "0x" + String(repeating: "b", count: 64)
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.stubUserOperation(
      chainId: RainChain.baseSepolia,
      transactionHash: minedHash,
      succeeded: true
    )
    let (manager, portal, builder) = portalManager(portal: mockPortal)
    builder.stubbedApproveData = "0x095ea7b3deadbeef"

    let result = try await manager.approveTokenAllowance(
      chainId: RainChain.baseSepolia,
      contractAddress: TestFixtures.tokenAddress,
      spender: spender
    )

    #expect(result.transactionHash == minedHash)
    #expect(portal.requestCalls.map(\.method).contains(.eth_getLogs))
  }

  /// An operation can be included and still revert inside the account. The bundler's transaction
  /// succeeds either way, so the event's own success flag is the only thing that answers.
  @Test("a reverted UserOperation throws rather than reporting a mined transaction")
  func approvalRejectsRevertedUserOperation() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.stubUserOperation(
      chainId: RainChain.baseSepolia,
      transactionHash: "0x" + String(repeating: "c", count: 64),
      succeeded: false
    )
    let (manager, _, builder) = portalManager(portal: mockPortal)
    builder.stubbedApproveData = "0x095ea7b3deadbeef"

    await #expect(throws: RainError.self) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.baseSepolia,
        contractAddress: TestFixtures.tokenAddress,
        spender: spender
      )
    }
  }

  @Test("a Portal failure on the approval is mapped, not leaked")
  func approvalPortalErrorIsMapped() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:\(RainChain.baseSepolia)",
      method: .eth_sendTransaction,
      error: NSError(domain: "PortalTest", code: 42)
    )
    let (manager, _, _) = portalManager(portal: mockPortal)

    await #expect(throws: RainError.self) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.baseSepolia,
        contractAddress: TestFixtures.tokenAddress,
        spender: spender
      )
    }
  }
}
