import Testing
import Foundation
import Web3
@testable import PortalSwift
@_spi(RainAdapter) @testable import RainCore
@testable import RainPortal

/// Manager-contract tests for send APIs: error wrapping, provider routing, decimals resolution.
/// The removed init/lifecycle cases ("throws sdkNotInitialized before initialization" / "after
/// wallet-agnostic initialize") are dropped; the `walletUnavailable` cases (Portal has no address)
/// remain.
@Suite("Send Token Tests")
struct SendTokenTests {

  // MARK: - sendNative

  @Test("sendNative throws walletUnavailable when provider has no address")
  func testSendNativeTokenNoWalletAddress() async throws {
    let mockPortal = MockPortal()
    mockPortal.mockAddresses.removeAll()
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  // MARK: - sendToken

  @Test("sendToken throws walletUnavailable when provider has no address")
  func testSendERC20TokenNoWalletAddress() async throws {
    let mockPortal = MockPortal()
    mockPortal.mockAddresses.removeAll()
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.sendToken(
        chainId: 1,
        contractAddress: TestFixtures.tokenAddress,
        to: TestFixtures.recipientAddress,
        amount: 100.0,
        decimals: 18
      )
    }
  }

  // MARK: - Happy paths via provider-agnostic stub

  @Test("sendNative returns provider tx hash and forwards from/to/value to the provider")
  func testSendNativeTokenRoutesToProvider() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    let expectedHash = "0x" + String(repeating: "a", count: 64)
    stub.sendTransactionHashToReturn = expectedHash

    let result = try await manager.sendNative(
      chainId: 1,
      to: TestFixtures.recipientAddress,
      amount: 1.5
    )

    #expect(result.transactionHash == expectedHash)
    #expect(stub.sendTransactionCalls.count == 1)
    #expect(stub.sendTransactionCalls[0].chainId == 1)
    #expect(stub.sendTransactionCalls[0].params.from == TestFixtures.walletAddress)
    // The manager validates the recipient and forwards its EIP-55 checksummed form.
    #expect(stub.sendTransactionCalls[0].params.to
      == (try RainWithdrawAddresses.checksummed(TestFixtures.recipientAddress, label: "to")))
    // Empty data for native transfers.
    #expect(stub.sendTransactionCalls[0].params.data == .empty)
  }

  @Test("sendNative encodes value as exact wei (no Double drift)")
  func testSendNativeEncodesExactWei() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    stub.sendTransactionHashToReturn = "0x" + String(repeating: "a", count: 64)

    _ = try await manager.sendNative(
      chainId: 1,
      to: TestFixtures.recipientAddress,
      amount: Decimal(string: "16.38")!
    )

    let expectedWei = BigUInt("16380000000000000000", radix: 10)!
    #expect(stub.sendTransactionCalls[0].params.value == "0x" + String(expectedWei, radix: 16))
  }

  @Test("sendToken returns provider tx hash and routes calldata to the token contract")
  func testSendERC20TokenRoutesToProvider() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    let expectedHash = "0x" + String(repeating: "b", count: 64)
    stub.sendTransactionHashToReturn = expectedHash

    let result = try await manager.sendToken(
      chainId: 1,
      contractAddress: TestFixtures.tokenAddress,
      to: TestFixtures.recipientAddress,
      amount: 100.0,
      decimals: 6
    )

    #expect(result.transactionHash == expectedHash)
    #expect(stub.sendTransactionCalls.count == 1)
    #expect(stub.sendTransactionCalls[0].params.to == TestFixtures.tokenAddress)
    #expect(stub.sendTransactionCalls[0].params.data.hasPrefix("0x"))
  }

  @Test("sendToken resolves decimals via the token store when the caller omits them")
  func testSendTokenResolvesDecimalsFromStore() async throws {
    // Build a manager whose token store is backed by a mock chain reader resolving decimals to 6.
    let configs = TestFixtures.configs()
    let reader = MockChainReader()
    reader.stubbedDecimals = 6
    let tokenStore = TokenMetadataStore(chainReader: reader)
    let stub = StubWalletProvider()
    stub.sendTransactionHashToReturn = "0x" + String(repeating: "d", count: 64)
    let manager = RainSdkManager(
      walletProvider: stub,
      networkConfigs: configs,
      transactionBuilder: MockTransactionBuilderService(networkConfigs: configs),
      tokenStore: tokenStore,
      providerId: ProviderId("stub"),
      capabilities: []
    )

    let unknownToken = "0x000000000000000000000000000000000000dEaD"

    // No decimals supplied → SDK resolves 6 from the store.
    _ = try await manager.sendToken(
      chainId: 1,
      contractAddress: unknownToken,
      to: TestFixtures.recipientAddress,
      amount: 2.0
    )
    let resolvedData = stub.sendTransactionCalls.last?.params.data
    #expect(reader.decimalsCalls.count == 1)

    // The same call with explicit decimals: 6 must produce identical calldata.
    _ = try await manager.sendToken(
      chainId: 1,
      contractAddress: unknownToken,
      to: TestFixtures.recipientAddress,
      amount: 2.0,
      decimals: Int?(6)
    )
    let explicitData = stub.sendTransactionCalls.last?.params.data

    #expect(resolvedData == explicitData)
  }
}
