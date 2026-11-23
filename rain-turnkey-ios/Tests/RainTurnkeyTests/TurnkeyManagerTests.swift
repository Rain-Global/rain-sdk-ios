import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// Core-manager behaviors exercised through the Turnkey adapter — moved here with the adapter.
@Suite("Turnkey Manager Tests", .serialized)
struct TurnkeyManagerTests {
  private let usdc = TestFixtures.authPullUsdcAddress
  private let spender = TestFixtures.authPullSpender

  @Test("Turnkey-backed manager resolves the wallet address")
  func testTurnkeyManagerResolvesAddress() async throws {
    let (manager, _, _) = TestManagers.turnkeyManager()

    let walletAddress = try await manager.getWalletAddress()
    #expect(walletAddress == MockTurnkey.defaultWalletAddress)
  }

  @Test("fee estimation prices the same calldata the approval would send")
  func feeEstimationUsesApprovalCalldata() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208")      // 21_000
      MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800")    // 20 gwei

      // Fee math, not the environment gate: stay on the chain whose gas mocks are stubbed above
      // and widen the gate to match, so this test measures one thing.
      let (manager, _, builder) = TestManagers.turnkeyManager(authPullChainIds: [1])
      builder.stubbedApproveData = "0x095ea7b3deadbeef"

      let fee = try await manager.estimateApprovalFee(
        chainId: 1,
        contractAddress: usdc,
        spender: spender
      )

      // 21_000 gas × 20 gwei = 0.00042 native units.
      #expect(fee == Decimal(string: "0.00042"))
      #expect(builder.approveCalls.count == 1)
      #expect(builder.approveCalls[0].amount == RainTokenAllowance.unlimitedRawAmount)
    }
  }
}
