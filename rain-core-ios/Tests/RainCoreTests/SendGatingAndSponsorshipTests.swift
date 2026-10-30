import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

/// Core's side of send gating and fee sponsorship: the `WalletProvider` hooks default to
/// "sendable everywhere, wallet pays", the manager consults them before signing, and fee
/// estimates ignore sponsorship — they quote the on-chain cost so a host can show the saving.
@Suite("Send gating & sponsorship (core)")
struct SendGatingAndSponsorshipTests {

  @Test("the WalletProvider hooks default to no gating and no sponsorship")
  func hookDefaults() throws {
    struct Minimal: WalletProvider {
      func address() async throws -> String { "0x" + String(repeating: "1", count: 40) }
      func sendTransaction(chainId: Int, params: WalletTransactionParams) async throws -> String { "" }
      func getBalance(chainId: Int, token: Token) async throws -> Balance { fatalError() }
      func getBalances(chainId: Int) async throws -> [Balance] { [] }
      func getTransactions(chainId: Int, limit: Int?, offset: Int?, order: RainTransactionOrder?) async throws -> [RainTransaction] { [] }
    }
    let provider = Minimal()
    try provider.requireSendSupport(chainId: 43114) // no-op
    #expect(provider.sponsorsFees(chainId: 1) == false)
    #expect(provider.sponsorsRent(chainId: RainChain.solanaMainnet) == false)
  }

  @Test("chainNotSupported carries RAIN_104 and names the chain")
  func errorCode() {
    let error = RainError.chainNotSupported(chainId: 43114, details: "read-only here")
    #expect(error.code == "RAIN_104")
    #expect(error.errorDescription?.contains("43114") == true)
    #expect(error.errorDescription?.contains("read-only here") == true)
  }

  @Test("withdrawCollateral fails closed on an unsupported chain before any withdrawal work")
  func withdrawGated() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    stub.unsupportedSendChainIds = [1]

    await #expect(throws: RainError.chainNotSupported(chainId: 1, details: "")) {
      _ = try await manager.withdrawCollateral(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 1,
        decimals: 6,
        adminSignature: TestFixtures.adminSignature(),
        nonce: 1
      )
    }
    // Refused at the gate: nothing was signed or sent.
    #expect(stub.sendTransactionCalls.isEmpty)
    #expect(stub.requireSendSupportCalls == [1])
  }

  @Test("prepareWithdrawal is NOT gated — it only signs, and the result is the host's own-RPC path")
  func prepareNotGated() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    stub.unsupportedSendChainIds = [1]

    let prepared = try await manager.prepareWithdrawal(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 1,
      decimals: 6,
      adminSignature: TestFixtures.adminSignature(),
      nonce: 1
    )

    #expect(prepared.evmParameters != nil)
    #expect(stub.requireSendSupportCalls.isEmpty)
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("approveTokenAllowance is gated before the wallet is touched")
  func approvalGated() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()
    stub.unsupportedSendChainIds = [RainChain.baseSepolia]

    await #expect(throws: RainError.chainNotSupported(chainId: RainChain.baseSepolia, details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.baseSepolia,
        contractAddress: TestFixtures.authPullTokens(for: [RainChain.baseSepolia])[RainChain.baseSepolia]!,
        spender: TestFixtures.authPullOperator,
        amount: nil
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a supported chain passes the gate and the withdrawal proceeds")
  func supportedChainProceeds() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()

    let hash = try await manager.withdrawCollateral(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 1,
      decimals: 6,
      adminSignature: TestFixtures.adminSignature(),
      nonce: 1
    )

    #expect(hash == stub.sendTransactionHashToReturn)
    #expect(stub.requireSendSupportCalls == [1])
  }

  /// `mapWithdrawalError` wraps everything it is handed; cancellation must never reach it.
  @Test("a cancelled withdrawal reaches the caller as CancellationError, not RAIN_501")
  func cancelledWithdrawalIsNotWrapped() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    stub.sendTransactionError = CancellationError()

    await #expect(throws: CancellationError.self) {
      _ = try await manager.withdrawCollateral(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 1,
        decimals: 6,
        adminSignature: TestFixtures.adminSignature(),
        nonce: 1
      )
    }
  }

  @Test("a sponsored provider still gets the chain's withdrawal-fee estimate — hosts show the saving")
  func sponsoredEstimateQuotesChainCost() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager(stub: FeeEstimatingStubWalletProvider())
    stub.sponsoredChainIds = [1]
    stub.estimatedFeeToReturn = 0.0031

    let fee = try await manager.estimateWithdrawalFee(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 1,
      decimals: 6,
      adminSignature: TestFixtures.adminSignature(),
      nonce: 1
    )

    #expect(fee == 0.0031)
    #expect(stub.estimateTransactionFeeCalls == [1])
  }

  @Test("the prepared-withdrawal fee estimate quotes the chain cost when sponsored too")
  func sponsoredPreparedEstimateQuotesChainCost() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager(stub: FeeEstimatingStubWalletProvider())
    stub.sponsoredChainIds = [1]
    stub.estimatedFeeToReturn = 0.0031
    let prepared = try await manager.prepareWithdrawal(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 1,
      decimals: 6,
      adminSignature: TestFixtures.adminSignature(),
      nonce: 1
    )

    #expect(try await manager.estimateWithdrawalFee(chainId: 1, prepared: prepared) == 0.0031)
    #expect(stub.estimateTransactionFeeCalls == [1])
  }
}
