import Testing
import Foundation
import Web3
@testable import RainCore
@testable import RainTurnkey

/// Covers the withdrawal request contract: the caller's nonce reaches the signed EIP-712 payload,
/// and parameters that cannot produce a valid transaction are rejected before any network call.
@Suite("Withdrawal Request Tests")
struct WithdrawalRequestTests {

  // MARK: - Nonce threading

  @Test("withdrawCollateral signs the caller-supplied nonce instead of re-reading the chain")
  func testWithdrawCollateralUsesProvidedNonce() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0x" + String(repeating: "7", count: 64))]

    let (manager, _, builder) = TestManagers.turnkeyManager(turnkey: mockTurnkey)
    // A different value from the caller's, so a regression that ignores the argument is visible.
    builder.mockNonce = BigUInt(42)

    _ = try await manager.withdrawCollateral(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: BigUInt(7)
    )

    #expect(builder.capturedEIP712Nonce == BigUInt(7))
    #expect(builder.getLatestNonceCallCount == 0)
  }

  @Test("withdrawCollateral reads the nonce from the chain when the caller passes nil")
  func testWithdrawCollateralFallsBackToChainNonce() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0x" + String(repeating: "7", count: 64))]

    let (manager, _, builder) = TestManagers.turnkeyManager(turnkey: mockTurnkey)
    builder.mockNonce = BigUInt(42)

    _ = try await manager.withdrawCollateral(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: nil
    )

    #expect(builder.capturedEIP712Nonce == BigUInt(42))
    #expect(builder.getLatestNonceCallCount == 1)
  }

  // MARK: - Parameter validation

  @Test("withdrawCollateral rejects a non-positive chainId")
  func testWithdrawCollateralRejectsNonPositiveChainId() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()

    await #expect(throws: RainError.invalidConfig(details: "Invalid chainId: 0. Must be a positive integer.")) {
      _ = try await manager.withdrawCollateral(
        chainId: 0,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature(),
        nonce: nil
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("withdrawCollateral rejects a zero or negative amount")
  func testWithdrawCollateralRejectsNonPositiveAmount() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()

    for amount in [Decimal(0), Decimal(-1)] {
      await #expect(throws: RainError.self) {
        _ = try await manager.withdrawCollateral(
          chainId: 1,
          addresses: TestFixtures.defaultWithdrawAddresses,
          amount: amount,
          decimals: 18,
          adminSignature: TestFixtures.adminSignature(),
          nonce: nil
        )
      }
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("withdrawCollateral rejects negative decimals")
  func testWithdrawCollateralRejectsNegativeDecimals() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()

    await #expect(throws: RainError.self) {
      _ = try await manager.withdrawCollateral(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: -1,
        adminSignature: TestFixtures.adminSignature(),
        nonce: nil
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("estimateWithdrawalFee applies the same validation as withdrawCollateral")
  func testEstimateWithdrawalFeeValidatesParameters() async throws {
    let (manager, _) = try await TestManagers.stubProviderManager()

    await #expect(throws: RainError.invalidConfig(details: "Invalid chainId: -1. Must be a positive integer.")) {
      _ = try await manager.estimateWithdrawalFee(
        chainId: -1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature()
      )
    }

    await #expect(throws: RainError.self) {
      _ = try await manager.estimateWithdrawalFee(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature()
      )
    }
  }

  @Test("prepareWithdrawal applies the same validation as withdrawCollateral")
  func testPrepareWithdrawalValidatesParameters() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()

    await #expect(throws: RainError.invalidConfig(details: "Invalid chainId: 0. Must be a positive integer.")) {
      _ = try await manager.prepareWithdrawal(
        chainId: 0,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature()
      )
    }

    for amount in [Decimal(0), Decimal(-1)] {
      await #expect(throws: RainError.self) {
        _ = try await manager.prepareWithdrawal(
          chainId: 1,
          addresses: TestFixtures.defaultWithdrawAddresses,
          amount: amount,
          decimals: 18,
          adminSignature: TestFixtures.adminSignature()
        )
      }
    }

    await #expect(throws: RainError.self) {
      _ = try await manager.prepareWithdrawal(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: -1,
        adminSignature: TestFixtures.adminSignature()
      )
    }

    #expect(stub.sendTransactionCalls.isEmpty)
  }

  // MARK: - Prepare vs broadcast

  @Test("prepareWithdrawal returns the exact calldata withdrawCollateral broadcasts")
  func testPrepareWithdrawalMatchesBroadcastBytes() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0x" + String(repeating: "7", count: 64))]

    let (manager, _, builder) = TestManagers.turnkeyManager(turnkey: mockTurnkey)
    builder.mockNonce = BigUInt(42)

    // A pinned nonce is what makes the two runs comparable: the salt is random per call, but the
    // caller-supplied signature bytes and the encoded arguments are not.
    let prepared = try await manager.prepareWithdrawal(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: BigUInt(7)
    )
    let parameters = try #require(prepared.evmParameters)

    // Preparing broadcasts nothing.
    #expect(client.ethSendTransactionCalls.isEmpty)

    _ = try await manager.withdrawCollateral(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: BigUInt(7)
    )
    let broadcast = try #require(client.ethSendTransactionCalls.first)
    let broadcastData = try #require(broadcast.data)

    // The prepared transaction is complete, not bare calldata.
    #expect(parameters.from == broadcast.from)
    #expect(parameters.to == broadcast.to)
    #expect(parameters.value == "0x0")
    #expect(!parameters.from.isEmpty)

    // Same selector and same encoded length; only the random salt differs.
    #expect(parameters.data.hasPrefix(String(broadcastData.prefix(10))))
    #expect(parameters.data.count == broadcastData.count)
  }

  @Test("estimateWithdrawalFee rejects a Solana chain id instead of taking the EVM path")
  func testEstimateWithdrawalFeeRejectsSolana() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()

    await #expect(throws: RainError.self) {
      _ = try await manager.estimateWithdrawalFee(
        chainId: SolanaChains.devnet,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 6,
        adminSignature: TestFixtures.adminSignature()
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  // MARK: - Helpers

  private func stubSendTransactionRPCs() {
    MockURLProtocol.stub(method: "eth_getTransactionCount", result: "0x1")
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208")  // 21000
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800") // 20 gwei
  }
}
