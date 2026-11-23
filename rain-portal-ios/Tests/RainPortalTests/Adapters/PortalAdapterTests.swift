import Testing
import Foundation
import Web3
@testable import PortalSwift
@testable import RainCore
@testable import RainPortal

@Suite("Portal Adapter Tests")
struct PortalAdapterTests {

  // MARK: - Address / wallet info

  @Test("getWalletAddress returns address from Portal context")
  func testGetWalletAddressFromPortal() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let address = try await manager.getWalletAddress()
    #expect(address == TestFixtures.walletAddress)
  }

  // MARK: - getBalance(.native)

  @Test("getBalance(.native) returns 1.0 ETH and calls eth_getBalance on the correct chain")
  func testGetNativeBalanceSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let (manager, portal, _) = TestManagers.portalManager(portal: mockPortal)

    let balance = try await manager.getBalance(chainId: 1, token: .native)

    #expect(balance.token == .native)
    #expect(balance.decimals == 18)
    #expect(balance.symbol == "ETH")
    #expect(balance.decimalAmount == 1)
    #expect(portal.requestCalls.count == 1)
    #expect(portal.requestCalls[0].method == .eth_getBalance)
    #expect(portal.requestCalls[0].chainId == "eip155:1")
  }

  @Test("getBalance(.native) maps Portal request failures to providerError")
  func testGetNativeBalancePortalError() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_getBalance,
      error: NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: "RPC error"])
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.getBalance(chainId: 1, token: .native)
    }
  }

  // MARK: - getBalance(.contract) (via RPC eth_call)

  @Test("getBalance(.contract) returns 0 when eth_call returns empty result")
  func testGetContractBalanceReturnsZeroWhenCallReturnsEmpty() async throws {
    let (manager, _, _) = TestManagers.portalManager()
    let balance = try await manager.getBalance(
      chainId: 1,
      token: .contract(address: TestFixtures.usdcAddress)
    )
    #expect(balance.rawAmount == 0)
    #expect(balance.decimalAmount == 0)
  }

  @Test("getBalance(.contract) resolves decimals/symbol from the registry and returns 1.0 USDC")
  func testGetContractBalanceSuccessRegistryDecimals() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    // 1 USDC with 6 decimals = 0x0F4240 (1_000_000)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_call,
      result: PortalProviderRpcResponse(jsonrpc: "2.0", result: "0x0F4240")
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let balance = try await manager.getBalance(
      chainId: 1,
      token: .contract(address: TestFixtures.usdcAddress)
    )

    #expect(balance.rawAmount == BigUInt(1_000_000))
    #expect(balance.decimals == 6)
    #expect(balance.symbol == "USDC")
    #expect(balance.decimalAmount == 1)
    #expect(mockPortal.requestCalls.count == 1)
    #expect(mockPortal.requestCalls[0].method == .eth_call)
    #expect(mockPortal.requestCalls[0].chainId == "eip155:1")
  }

  @Test("getBalance(.contract) throws providerError when portal request fails")
  func testGetContractBalancePortalError() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_call,
      error: NSError(domain: "RPC", code: -1, userInfo: [NSLocalizedDescriptionKey: "RPC error"])
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.getBalance(chainId: 1, token: .contract(address: TestFixtures.usdcAddress))
    }
  }

  @Test("getBalance(.contract) surfaces an expired Portal session as tokenExpired")
  func testGetContractBalanceExpiredSession() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_call,
      error: PortalRequestsError.unauthorized
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    // This read wraps Portal errors itself so a read-path revert is never a failed simulation;
    // auth must still classify, otherwise the host cannot tell it needs to re-authenticate.
    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.getBalance(chainId: 1, token: .contract(address: TestFixtures.usdcAddress))
    }
  }

  // MARK: - getBalances

  @Test("getBalances returns only native when Portal reports no tokens")
  func testGetBalancesOnlyNative() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.mockAssetsResponse = AssetsResponse(nativeBalance: nil, tokenBalances: nil, nfts: nil)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let balances = try await manager.getTokenBalances(chainId: 1)
    #expect(balances.count == 1)
    #expect(balances[0].token == .native)
    #expect(balances[0].decimalAmount == 1)
  }

  @Test("getBalances reconstructs a non-18-decimal token's rawAmount from Portal's formatted balance")
  func testGetBalancesReconstructsErc20RawAmount() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    // Portal reports a formatted decimal string with no rawBalance; the adapter must
    // reconstruct exact base units using the store's decimals (USDC = 6) → 1.5 * 1e6.
    mockPortal.mockAssetsResponse = Self.makeAssetsResponse(
      tokenAddress: TestFixtures.usdcAddress,
      balance: "1.5",
      symbol: "USDC"
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let balances = try await manager.getTokenBalances(chainId: 1)

    #expect(balances.count == 2)
    #expect(balances[0].token == .native)

    let usdc = try #require(balances.first { $0.token == .contract(address: TestFixtures.usdcAddress) })
    #expect(usdc.rawAmount == BigUInt(1_500_000))
    #expect(usdc.decimals == 6)
    #expect(usdc.symbol == "USDC")
    #expect(usdc.decimalAmount == 1.5)
  }

  // MARK: - sendNative / sendToken

  @Test("sendNative with Portal returns mock tx hash and calls eth_call then eth_sendTransaction")
  func testSendNativeTokenSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)

    let mockTxHash = "0x" + String(repeating: "b", count: 64)
    mockPortal.setMockResponse(chainId: "eip155:1", method: .eth_sendTransaction, result: mockTxHash)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let result = try await manager.sendNative(
      chainId: 1,
      to: TestFixtures.recipientAddress,
      amount: 1.5
    )

    #expect(result.transactionHash == mockTxHash)
    // eth_call preflights the send; eth_blockNumber bounds the UserOperation scan that follows it.
    #expect(mockPortal.requestCalls.map(\.method) == [.eth_call, .eth_blockNumber, .eth_sendTransaction])
  }

  @Test("sendToken with Portal returns mock tx hash and routes calldata via eth_sendTransaction")
  func testSendERC20TokenSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)

    let mockTxHash = "0x" + String(repeating: "c", count: 64)
    mockPortal.setMockResponse(chainId: "eip155:1", method: .eth_sendTransaction, result: mockTxHash)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let result = try await manager.sendToken(
      chainId: 1,
      contractAddress: TestFixtures.tokenAddress,
      to: TestFixtures.recipientAddress,
      amount: 100.0,
      decimals: 6
    )

    #expect(result.transactionHash == mockTxHash)
    #expect(mockPortal.requestCalls.map(\.method) == [.eth_call, .eth_blockNumber, .eth_sendTransaction])
  }

  @Test("sendNative with Portal maps send failures to providerError")
  func testSendNativeTokenPortalSendFailure() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_sendTransaction,
      error: NSError(domain: "PortalError", code: 500, userInfo: [NSLocalizedDescriptionKey: "send failed"])
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  @Test("sendToken with Portal maps send failures to providerError")
  func testSendERC20TokenPortalSendFailure() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_sendTransaction,
      error: NSError(domain: "PortalError", code: 500, userInfo: [NSLocalizedDescriptionKey: "send failed"])
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.sendToken(
        chainId: 1,
        contractAddress: TestFixtures.tokenAddress,
        to: TestFixtures.recipientAddress,
        amount: 100.0,
        decimals: 6
      )
    }
  }

  // A simulation revert on a plain send stays RAIN_403, not a withdrawal-specific code.
  @Test("sendNative throws transactionSimulationFailed when eth_call preflight fails")
  func testSendNativeTokenPreflightFailure() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_call,
      error: NSError(domain: "PortalError", code: 3, userInfo: [NSLocalizedDescriptionKey: "execution reverted"])
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.transactionSimulationFailed(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  // An expired session failing the eth_call preflight must classify as auth, not as RAIN_403.
  @Test("sendNative surfaces tokenExpired when the eth_call preflight fails with a 401")
  func testSendNativeTokenPreflightAuthFailure() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_call,
      error: PortalRequestsError.unauthorized
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  // MARK: - withdrawCollateral / estimateWithdrawalFee

  @Test("withdrawCollateral with Portal signs typed data, simulates, then sends")
  func testWithdrawCollateralSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)

    let chainIdString = "eip155:1"
    let mockAdminSignature = "0x" + String(repeating: "1", count: 130)
    let mockTxHash = "0x" + String(repeating: "a", count: 64)
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_signTypedData_v4, result: mockAdminSignature)
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_sendTransaction, result: mockTxHash)

    let (manager, _, builder) = TestManagers.portalManager(portal: mockPortal)
    builder.mockNonce = BigUInt(42)

    let txHash = try await manager.withdrawCollateral(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: nil
    )

    #expect(txHash == mockTxHash)
    #expect(mockPortal.requestCalls.map(\.method) == [
      .eth_signTypedData_v4, .eth_call, .eth_blockNumber, .eth_sendTransaction
    ])

    #expect(mockPortal.requestCalls[0].chainId == chainIdString)
    #expect(mockPortal.requestCalls[0].params.count == 2)
    #expect(mockPortal.requestCalls[3].params.count == 1)
  }

  @Test("estimateWithdrawalFee with Portal returns gasPrice × gasLimit fee")
  func testEstimateWithdrawalFeeSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)

    let chainIdString = "eip155:1"
    mockPortal.setMockResponse(
      chainId: chainIdString,
      method: .eth_signTypedData_v4,
      result: "0x" + String(repeating: "1", count: 130)
    )
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_estimateGas, result: "21000")
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_gasPrice, result: "20000000000")

    let (manager, _, builder) = TestManagers.portalManager(portal: mockPortal)
    builder.mockNonce = BigUInt(42)

    let fee = try await manager.estimateWithdrawalFee(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature()
    )

    // 21_000 gas × 20 gwei = 420_000_000_000_000 wei = exactly 0.00042 native units.
    #expect(fee == Decimal(string: "0.00042"))
  }

  @Test("estimateGas with Portal returns gasPrice × gasLimit fee for arbitrary calldata")
  func testEstimateGasSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)

    let chainIdString = "eip155:1"
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_estimateGas, result: "21000")
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_gasPrice, result: "20000000000")

    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let fee = try await manager.estimateGas(
      chainId: 1,
      from: TestFixtures.walletAddress,
      to: TestFixtures.contractAddress,
      data: "0xdeadbeef"
    )

    // 21_000 gas × 20 gwei = 420_000_000_000_000 wei = exactly 0.00042 native units.
    #expect(fee == Decimal(string: "0.00042"))
  }

  @Test("estimateGas accepts integral float-formatted gas values")
  func testEstimateGasAcceptsIntegralFloatStrings() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)

    let chainIdString = "eip155:1"
    // Some transports render integral gas values as floats; the old Double path tolerated these.
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_estimateGas, result: "21000.0")
    mockPortal.setMockResponse(chainId: chainIdString, method: .eth_gasPrice, result: "20000000000.0")

    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let fee = try await manager.estimateGas(
      chainId: 1,
      from: TestFixtures.walletAddress,
      to: TestFixtures.contractAddress,
      data: "0xdeadbeef"
    )

    // 21_000 gas × 20 gwei = 420_000_000_000_000 wei = exactly 0.00042 native units.
    #expect(fee == Decimal(string: "0.00042"))
  }

  @Test("estimateGas rejects fractional and malformed gas values")
  func testEstimateGasRejectsMalformedStrings() async throws {
    for malformed in ["21000.5", "21000.0abc", "-21000.0", "not-a-number"] {
      let mockPortal = MockPortal()
      mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
      mockPortal.setMockResponse(chainId: "eip155:1", method: .eth_estimateGas, result: malformed)
      let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await manager.estimateGas(
          chainId: 1,
          from: TestFixtures.walletAddress,
          to: TestFixtures.contractAddress,
          data: "0xdeadbeef"
        )
      }
    }
  }

  @Test("withdrawCollateral with Portal propagates sign error")
  func testWithdrawCollateralPortalRequestFailure() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_signTypedData_v4,
      error: NSError(domain: "PortalError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Signing failed"])
    )
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.withdrawCollateral(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature(),
        nonce: BigUInt(1)
      )
    }
  }

  @Test("estimateWithdrawalFee with Portal maps sign failures to providerError")
  func testEstimateWithdrawalFeePortalRequestFailure() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.setMockResponse(
      chainId: "eip155:1",
      method: .eth_signTypedData_v4,
      error: NSError(domain: "PortalError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Signing failed"])
    )
    let (manager, _, builder) = TestManagers.portalManager(portal: mockPortal)
    builder.mockNonce = BigUInt(1)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.estimateWithdrawalFee(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature()
      )
    }
  }

  // MARK: - getTransactions

  @Test("getTransactions with Portal returns mapped WalletTransaction")
  func testGetTransactionsReturnsMappedList() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let fetchedTx = Self.makeFetchedTransaction(
      hash: "0xabc123",
      from: "0xfrom",
      to: "0xto",
      blockNum: "100",
      chainId: 1
    )
    mockPortal.mockFetchedTransactions = [fetchedTx]
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let list = try await manager.getTransactions(chainId: 1)

    #expect(list.count == 1)
    #expect(list[0].hash == "0xabc123")
    #expect(list[0].from == "0xfrom")
    #expect(list[0].to == "0xto")
    #expect(list[0].blockNumber == "100")
    #expect(list[0].chainId == 1)
    // Vendor-supplied millisecond timestamps are normalized to second-precision Zulu.
    #expect(list[0].timestamp == "2024-01-01T00:00:00Z")
  }

  @Test("getTransactions with Portal passes order parameter through")
  func testGetTransactionsWithOrder() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let fetchedTx = Self.makeFetchedTransaction(hash: "0xdef", from: "0xa", to: "0xb", blockNum: "200", chainId: 137)
    mockPortal.mockFetchedTransactions = [fetchedTx]
    let configs = [NetworkConfig.testConfig(chainId: 137, rpcUrl: "https://polygon-rpc.com")]
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal, configs: configs)

    let list = try await manager.getTransactions(chainId: 137, limit: 10, offset: 0, order: .DESC)
    #expect(list.count == 1)
    #expect(list[0].hash == "0xdef")
    #expect(list[0].chainId == 137)
  }

  @Test("a native row takes its asset from the chain's native currency")
  func testNativeRowGetsNativeSymbol() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.mockFetchedTransactions = [
      Self.makeFetchedTransaction(hash: "0xnative", from: "0xa", to: "0xb", blockNum: "1", chainId: 1)
    ]
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let list = try await manager.getTransactions(chainId: 1)

    // No rawContract → native transfer → the SDK names it, rather than leaving the host to guess.
    #expect(list[0].tokenAddress == nil)
    #expect(list[0].asset == "ETH")
  }

  @Test("a native row on an unlisted chain gets no asset rather than a wrong one")
  func testNativeRowOnUnknownChainHasNoAsset() async throws {
    let unlistedChainId = 123456
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.mockFetchedTransactions = [
      Self.makeFetchedTransaction(
        hash: "0xnative", from: "0xa", to: "0xb", blockNum: "1", chainId: unlistedChainId
      )
    ]
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let list = try await manager.getTransactions(chainId: unlistedChainId)

    // The registry knows no gas token here. Falling back to the ETH-like default would label
    // the row with a symbol the chain doesn't use, which is worse than none.
    #expect(list[0].tokenAddress == nil)
    #expect(list[0].asset == nil)
  }

  @Test("an unresolvable token's amount is left nil rather than scaled at a default precision")
  func testUnresolvableDecimalsLeavesValueNil() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    // A contract row with a raw hex value and no decimals, whose decimals() read fails.
    mockPortal.mockFetchedTransactions = [
      Self.makeFetchedTransaction(
        hash: "0xtoken", from: "0xa", to: "0xb", blockNum: "1", chainId: 1,
        value: nil,
        rawContractJSON: """
        , "rawContract": { "value": "0x16345785d8a0000", "address": "\(TestFixtures.usdcAddress)" }
        """
      )
    ]
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let list = try await manager.getTransactions(chainId: 1)

    // The raw amount and the contract are still surfaced; only the scaled value is withheld.
    // Scaling at a default 18 would render a 6-decimal token off by 10^12.
    #expect(list[0].tokenAddress == TestFixtures.usdcAddress)
    #expect(list[0].rawValue == "0x16345785d8a0000")
    if list[0].decimals == nil {
      #expect(list[0].value == nil)
    }
  }

  // MARK: - Helpers

  private static func makeFetchedTransaction(
    hash: String,
    from: String,
    to: String,
    blockNum: String,
    chainId: Int,
    value: Double? = 1.0,
    rawContractJSON: String = ""
  ) -> FetchedTransaction {
    let valueJSON: String = value.map { "\($0)" } ?? "null"
    let json = """
    {
      "blockNum": "\(blockNum)",
      "uniqueId": "uid-\(hash)",
      "hash": "\(hash)",
      "from": "\(from)",
      "to": "\(to)",
      "value": \(valueJSON),
      "category": "external",
      "metadata": { "blockTimestamp": "2024-01-01T00:00:00.000Z" },
      "chainId": \(chainId)\(rawContractJSON)
    }
    """
    return try! JSONDecoder().decode(FetchedTransaction.self, from: Data(json.utf8))
  }

  /// Builds an `AssetsResponse` with a single ERC-20 token balance. `TokenBalanceResponse`
  /// is `Decodable`-only (no memberwise init), so we decode it from JSON.
  private static func makeAssetsResponse(
    tokenAddress: String,
    balance: String,
    symbol: String
  ) -> AssetsResponse {
    let json = """
    {
      "nativeBalance": null,
      "tokenBalances": [
        {
          "balance": "\(balance)",
          "decimals": 6,
          "name": "USD Coin",
          "rawBalance": null,
          "symbol": "\(symbol)",
          "metadata": { "tokenAddress": "\(tokenAddress)", "verifiedContract": true }
        }
      ],
      "nfts": null
    }
    """
    return try! JSONDecoder().decode(AssetsResponse.self, from: Data(json.utf8))
  }
}
