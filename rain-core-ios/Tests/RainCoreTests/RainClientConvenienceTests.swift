import Testing
import CoreGraphics
import Foundation
import Web3
@testable import RainCore

/// Pins the `RainClient` convenience overloads to the protocol requirement.
///
/// `getTransactions` deliberately has NO full-signature extension member: one with the
/// requirement's exact signature would act as a default witness whose body dispatches back to
/// itself, so a conformance omitting the method would compile and then recurse forever. With
/// only the reduced-arity convenience below, omitting `getTransactions(chainId:limit:offset:order:)`
/// from a conformance fails to compile — which is the guarantee this suite documents.
@Suite("RainClient Convenience Overloads")
struct RainClientConvenienceTests {

  @Test("getTransactions(chainId:) forwards nil paging and order to the requirement")
  func getTransactionsConvenienceForwards() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.getTransactions(chainId: 137)

    let call = try #require(spy.getTransactionsCalls.first)
    #expect(spy.getTransactionsCalls.count == 1)
    #expect(call.chainId == 137)
    #expect(call.limit == nil)
    #expect(call.offset == nil)
    #expect(call.order == nil)
  }

  @Test("full-arity getTransactions reaches the witness unchanged")
  func fullArityReachesWitness() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.getTransactions(chainId: 1, limit: 20, offset: 5, order: .DESC)

    let call = try #require(spy.getTransactionsCalls.first)
    #expect(call.chainId == 1)
    #expect(call.limit == 20)
    #expect(call.offset == 5)
    #expect(call.order == .DESC)
  }

  @Test("approveTokenAllowance(chainId:contractAddress:spender:) means unlimited")
  func approvalConvenienceDefaultsToUnlimited() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.approveTokenAllowance(
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator"
    )

    let call = try #require(spy.approvalCalls.first)
    #expect(call.amount == nil)
  }

  @Test("the amount-carrying approval reaches the client unchanged")
  func approvalConvenienceForwardsAmount() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.approveTokenAllowance(
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator",
      amount: 250
    )

    let call = try #require(spy.approvalCalls.first)
    #expect(call.amount == 250)
  }

  @Test("getTokenAllowance(chainId:contractAddress:spender:) reads the client's own wallet")
  func allowanceConvenienceDefaultsToOwnWallet() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.getTokenAllowance(
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator"
    )

    let call = try #require(spy.allowanceCalls.first)
    #expect(call.owner == nil)
  }

  @Test("the fee-estimate overloads forward the same defaults as the approval ones")
  func approvalFeeConvenienceForwards() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.estimateApprovalFee(
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator"
    )
    _ = try await client.estimateApprovalFee(
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator",
      amount: 10
    )

    #expect(spy.approvalFeeCalls.count == 2)
    #expect(spy.approvalFeeCalls[0].amount == nil)
    #expect(spy.approvalFeeCalls[1].amount == 10)
  }

  @Test("the confirmation overloads default to this client's own wallet")
  func confirmConvenienceDefaultsToOwnWallet() async throws {
    let spy = SpyRainClient()
    let client: any RainClient = spy

    _ = try await client.confirmTokenAllowance(
      transactionHash: "0xhash",
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator"
    )
    _ = try await client.confirmTokenAllowance(
      transactionHash: "0xhash",
      chainId: 8453,
      contractAddress: "0xtoken",
      spender: "0xoperator",
      amount: 250
    )

    #expect(spy.confirmCalls.count == 2)
    #expect(spy.confirmCalls[0].owner == nil)
    #expect(spy.confirmCalls[0].amount == nil)
    #expect(spy.confirmCalls[1].owner == nil)
    #expect(spy.confirmCalls[1].amount == 250)
  }
}

/// Minimal conformance: records `getTransactions` calls; everything unused traps.
private final class SpyRainClient: RainClient, @unchecked Sendable {
  struct GetTransactionsCall {
    let chainId: Int
    let limit: Int?
    let offset: Int?
    let order: RainTransactionOrder?
  }

  struct ApprovalCall {
    let chainId: Int
    let contractAddress: String
    let spender: String
    let amount: Decimal?
  }

  struct AllowanceCall {
    let chainId: Int
    let contractAddress: String
    let owner: String?
    let spender: String
  }

  struct ConfirmCall {
    let transactionHash: String
    let chainId: Int
    let contractAddress: String
    let spender: String
    let amount: Decimal?
    let owner: String?
  }

  private let lock = NSLock()
  private var _getTransactionsCalls: [GetTransactionsCall] = []
  private var _approvalCalls: [ApprovalCall] = []
  private var _approvalFeeCalls: [ApprovalCall] = []
  private var _allowanceCalls: [AllowanceCall] = []
  private var _confirmCalls: [ConfirmCall] = []

  var getTransactionsCalls: [GetTransactionsCall] {
    lock.lock(); defer { lock.unlock() }
    return _getTransactionsCalls
  }
  var approvalCalls: [ApprovalCall] {
    lock.lock(); defer { lock.unlock() }
    return _approvalCalls
  }
  var approvalFeeCalls: [ApprovalCall] {
    lock.lock(); defer { lock.unlock() }
    return _approvalFeeCalls
  }
  var allowanceCalls: [AllowanceCall] {
    lock.lock(); defer { lock.unlock() }
    return _allowanceCalls
  }
  var confirmCalls: [ConfirmCall] {
    lock.lock(); defer { lock.unlock() }
    return _confirmCalls
  }

  var providerId: ProviderId { ProviderId("spy") }
  var capabilities: Set<Capability> { [] }
  var isInitialized: Bool { true }
  var authPullChainIds: Set<Int> { [8453] }
  func reset() {}

  func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    lock.withLock {
      _getTransactionsCalls.append(
        GetTransactionsCall(chainId: chainId, limit: limit, offset: offset, order: order)
      )
    }
    return []
  }

  func withdrawCollateral(
    chainId: Int, addresses: RainWithdrawAddresses, amount: Decimal, decimals: Int,
    adminSignature: RainAdminSignature, nonce: BigUInt?
  ) async throws -> String { fatalError("unused") }

  func prepareWithdrawal(
    chainId: Int, addresses: RainWithdrawAddresses, amount: Decimal, decimals: Int,
    adminSignature: RainAdminSignature, nonce: BigUInt?
  ) async throws -> RainPreparedWithdrawal { fatalError("unused") }

  func estimateGas(chainId: Int, from: String, to: String, data: String) async throws -> Decimal {
    fatalError("unused")
  }

  func estimateWithdrawalFee(
    chainId: Int, addresses: RainWithdrawAddresses, amount: Decimal, decimals: Int,
    adminSignature: RainAdminSignature, nonce: BigUInt?
  ) async throws -> Decimal { fatalError("unused") }

  func estimateWithdrawalFee(
    chainId: Int, prepared: RainPreparedWithdrawal
  ) async throws -> Decimal { fatalError("unused") }

  func getWalletAddress() async throws -> String { fatalError("unused") }
  func getWalletAddress(chainId: Int) async throws -> String { fatalError("unused") }

  func generateAddressQRCode(
    address: String?, dimension: Int, backgroundColor: CGColor?, foregroundColor: CGColor?
  ) async throws -> Data { fatalError("unused") }

  func getBalance(chainId: Int, token: Token) async throws -> Balance { fatalError("unused") }
  func getTokenBalances(chainId: Int) async throws -> [Balance] { fatalError("unused") }
  func getAllBalances() async throws -> [Balance] { fatalError("unused") }

  func sendNative(chainId: Int, to: String, amount: Decimal) async throws -> RainTokenTransferResult {
    fatalError("unused")
  }

  func sendToken(
    chainId: Int, contractAddress: String, to: String, amount: Decimal, decimals: Int?
  ) async throws -> RainTokenTransferResult { fatalError("unused") }

  func approveTokenAllowance(
    chainId: Int, contractAddress: String, spender: String, amount: Decimal?
  ) async throws -> RainTokenApprovalResult {
    lock.withLock {
      _approvalCalls.append(
        ApprovalCall(chainId: chainId, contractAddress: contractAddress, spender: spender, amount: amount)
      )
    }
    return RainTokenApprovalResult(transactionHash: "0xspy")
  }

  func getTokenAllowance(
    chainId: Int, contractAddress: String, spender: String, owner: String?
  ) async throws -> RainTokenAllowance {
    lock.withLock {
      _allowanceCalls.append(
        AllowanceCall(chainId: chainId, contractAddress: contractAddress, owner: owner, spender: spender)
      )
    }
    return RainTokenAllowance(
      chainId: chainId,
      tokenAddress: contractAddress,
      owner: owner ?? "0x",
      spender: spender,
      rawAmount: 0,
      decimals: 6
    )
  }

  func estimateApprovalFee(
    chainId: Int, contractAddress: String, spender: String, amount: Decimal?
  ) async throws -> Decimal {
    lock.withLock {
      _approvalFeeCalls.append(
        ApprovalCall(chainId: chainId, contractAddress: contractAddress, spender: spender, amount: amount)
      )
    }
    return 0
  }

  func confirmTokenAllowance(
    transactionHash: String, chainId: Int, contractAddress: String, spender: String,
    amount: Decimal?, owner: String?
  ) async throws -> RainTokenAllowance {
    lock.withLock {
      _confirmCalls.append(
        ConfirmCall(
          transactionHash: transactionHash, chainId: chainId, contractAddress: contractAddress,
          spender: spender, amount: amount, owner: owner
        )
      )
    }
    return RainTokenAllowance(
      chainId: chainId,
      tokenAddress: contractAddress,
      owner: owner ?? "0x",
      spender: spender,
      rawAmount: RainTokenAllowance.unlimitedRawAmount,
      decimals: 6
    )
  }

  func registerTokens(_ tokens: [TokenInfo]) async throws {}
}
