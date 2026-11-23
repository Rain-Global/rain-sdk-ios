import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

/// Wallet-agnostic transaction-building tests. In the modular API these methods live on
/// ``RainSdk`` (public) and, bound to a resolved client's shared services, on ``RainSdkManager``
/// (internal). The monolith's `RainSDKManager()` + `initialize` lifecycle is gone, so the
/// "before initialization" cases are dropped — a manager is now always constructed with a
/// transaction builder — and the remaining cases build a manager directly around a stub provider.
@Suite("Transaction Building Tests")
struct TransactionBuildingTests {

  /// Builds a `RainSdkManager` bound to a `StubWalletProvider` and the given transaction builder,
  /// so tests can exercise `buildEIP712Message` / `buildWithdrawTransactionData` with either a
  /// mock or a real builder.
  private func manager(
    builder: TransactionBuilderProtocol,
    configs: [NetworkConfig] = TestFixtures.configs()
  ) -> RainSdkManager {
    let tokenStore = TokenMetadataStore(chainReader: EVMChainReader(networkConfigs: configs))
    return RainSdkManager(
      walletProvider: StubWalletProvider(),
      networkConfigs: configs,
      transactionBuilder: builder,
      tokenStore: tokenStore,
      providerId: ProviderId("stub"),
      capabilities: []
    )
  }

  private func mockBuilderManager(
    configs: [NetworkConfig] = TestFixtures.configs()
  ) -> (RainSdkManager, MockTransactionBuilderService) {
    let mockBuilder = MockTransactionBuilderService(networkConfigs: configs)
    return (manager(builder: mockBuilder, configs: configs), mockBuilder)
  }

  private func realBuilderManager(
    configs: [NetworkConfig] = TestFixtures.configs()
  ) -> RainSdkManager {
    manager(builder: TransactionBuilderService(networkConfigs: configs), configs: configs)
  }

  // MARK: - Salt generation

  @Test("generateSalt returns 32 unpredictable bytes, never all zeros")
  func testGenerateSaltIsNonZeroAndUnique() {
    let builder = TransactionBuilderService(networkConfigs: TestFixtures.configs())

    let salts = (0..<100).map { _ in builder.generateSalt() }
    for salt in salts {
      #expect(salt.count == 32)
      #expect(salt.contains { $0 != 0 })
    }
    #expect(Set(salts).count == salts.count)
  }

  // MARK: - buildEIP712Message success cases

  @Test("buildEIP712Message succeeds with valid inputs and provided nonce")
  func testBuildEIP712MessageWithNonce() async throws {
    let manager = realBuilderManager()

    let chainId = 1
    let nonce = BigUInt(42)
    let amount: Decimal = 100.0
    let decimals = 18

    let message = try await manager.buildEIP712MessageForTest(
      chainId: chainId,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: amount,
      decimals: decimals,
      nonce: nonce
    )

    let jsonObject = try parseJSON(message)
    #expect(jsonObject["primaryType"] as? String == "Withdraw")

    // The message carries checksum-normalized addresses — the same forms the calldata uses.
    let checksummed = try TestFixtures.defaultWithdrawAddresses.validated()
    let domain = jsonObject["domain"] as? [String: Any]
    #expect(domain?["name"] as? String == "Collateral")
    #expect(domain?["version"] as? String == "2")
    #expect(domain?["chainId"] as? Int == chainId)
    #expect(domain?["verifyingContract"] as? String == checksummed.proxyAddress)
    #expect(domain?["salt"] != nil)

    let messageData = jsonObject["message"] as? [String: Any]
    #expect(messageData?["user"] as? String == TestFixtures.walletAddress)
    #expect(messageData?["asset"] as? String == checksummed.tokenAddress)
    #expect(messageData?["recipient"] as? String == checksummed.recipientAddress)
    #expect(messageData?["nonce"] as? String == nonce.description)

    let expectedAmount = try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
    #expect(messageData?["amount"] as? String == expectedAmount.description)
  }

  @Test("buildEIP712Message fetches nonce from contract when nil")
  func testBuildEIP712MessageWithNilNonce() async throws {
    let (manager, mockBuilder) = mockBuilderManager()
    mockBuilder.mockNonce = BigUInt(42)

    let message = try await manager.buildEIP712MessageForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      nonce: nil
    )

    let messageData = try parseJSON(message)["message"] as? [String: Any]
    #expect(messageData?["nonce"] as? String == "42")
  }

  @Test("buildEIP712Message handles zero amount")
  func testBuildEIP712MessageZeroAmount() async throws {
    let manager = realBuilderManager()

    let message = try await manager.buildEIP712MessageForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 0.0,
      decimals: 18,
      nonce: BigUInt(0)
    )

    let messageData = try parseJSON(message)["message"] as? [String: Any]
    #expect(messageData?["amount"] as? String == "0")
  }

  @Test("buildEIP712Message handles 6-decimal tokens (USDC-like)")
  func testBuildEIP712MessageDifferentDecimals() async throws {
    let manager = realBuilderManager()

    let message = try await manager.buildEIP712MessageForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.5,
      decimals: 6,
      nonce: BigUInt(1)
    )

    let messageData = try parseJSON(message)["message"] as? [String: Any]
    #expect(messageData?["amount"] as? String == "100500000")
  }

  @Test("buildEIP712Message generates different salt on each call")
  func testBuildEIP712MessageDifferentSalt() async throws {
    let manager = realBuilderManager()

    let (message1, salt1) = try await manager.buildEIP712PairForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      nonce: BigUInt(1)
    )
    let (message2, salt2) = try await manager.buildEIP712PairForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      nonce: BigUInt(1)
    )

    #expect(message1 != message2)
    #expect(salt1 != salt2)
    #expect(salt1.hasPrefix("0x"))
  }

  @Test("buildEIP712Message handles very large amounts")
  func testBuildEIP712MessageLargeAmount() async throws {
    let manager = realBuilderManager()
    let amount: Decimal = 1_000_000_000.0
    let decimals = 18

    let message = try await manager.buildEIP712MessageForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: amount,
      decimals: decimals,
      nonce: BigUInt(1)
    )

    let messageData = try parseJSON(message)["message"] as? [String: Any]
    // Exact base-unit value: 1_000_000_000 (10^9) * 10^18 decimals = 10^27 ("1" + 27 zeros).
    let expectedAmount = BigUInt("1" + String(repeating: "0", count: 27), radix: 10)!
    #expect(messageData?["amount"] as? String == expectedAmount.description)
  }

  @Test("buildEIP712Message respects different chain IDs")
  func testBuildEIP712MessageDifferentChainIds() async throws {
    let configs = [
      NetworkConfig.testConfig(chainId: 1, rpcUrl: "https://mainnet.infura.io/v3/test"),
      NetworkConfig.testConfig(chainId: 137, rpcUrl: "https://polygon-rpc.com")
    ]
    let manager = realBuilderManager(configs: configs)

    let message1 = try await manager.buildEIP712MessageForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      nonce: BigUInt(1)
    )
    let message137 = try await manager.buildEIP712MessageForTest(
      chainId: 137,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      nonce: BigUInt(1)
    )

    #expect((try parseJSON(message1)["domain"] as? [String: Any])?["chainId"] as? Int == 1)
    #expect((try parseJSON(message137)["domain"] as? [String: Any])?["chainId"] as? Int == 137)
  }

  // MARK: - buildEIP712Message failure cases

  @Test("buildEIP712Message throws invalidConfig for unknown chainId when nonce is nil")
  func testBuildEIP712MessageInvalidChainId() async throws {
    let manager = realBuilderManager()

    await #expect(throws: RainError.invalidConfig(details: "No RPC endpoint configured for chainId=999")) {
      try await manager.buildEIP712MessageForTest(
        chainId: 999,
        walletAddress: TestFixtures.walletAddress,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        nonce: nil
      )
    }
  }

  @Test("buildEIP712Message succeeds with unknown chainId when nonce is provided")
  func testBuildEIP712MessageInvalidChainIdWithNonce() async throws {
    let manager = realBuilderManager()

    let message = try await manager.buildEIP712MessageForTest(
      chainId: 999,
      walletAddress: TestFixtures.walletAddress,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      nonce: BigUInt(1)
    )

    let domain = try parseJSON(message)["domain"] as? [String: Any]
    #expect(domain?["chainId"] as? Int == 999)
  }

  @Test("buildEIP712Message rejects an invalid wallet address before building")
  func testBuildEIP712MessageInvalidWalletAddress() async throws {
    let manager = realBuilderManager()

    await #expect(throws: RainError.invalidConfig(details: "Invalid walletAddress format: invalid-address")) {
      try await manager.buildEIP712MessageForTest(
        chainId: 1,
        walletAddress: "invalid-address",
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        nonce: BigUInt(1)
      )
    }
  }

  @Test("buildEIP712Message checksum-normalizes a mixed-case token address")
  func testBuildEIP712MessageChecksumsMixedCase() async throws {
    let manager = realBuilderManager()
    let addresses = RainWithdrawAddresses(
      proxyAddress: TestFixtures.proxyAddress,
      controllerAddress: TestFixtures.contractAddress,
      tokenAddress: TestFixtures.usdcAddress.lowercased(),
      recipientAddress: TestFixtures.recipientAddress
    )

    let message = try await manager.buildEIP712MessageForTest(
      chainId: 1,
      walletAddress: TestFixtures.walletAddress,
      addresses: addresses,
      amount: 1.0,
      decimals: 6,
      nonce: BigUInt(1)
    )

    let messageData = try parseJSON(message)["message"] as? [String: Any]
    #expect(messageData?["asset"] as? String == TestFixtures.usdcAddress)
  }

  // MARK: - buildWithdrawTransactionData

  /// Drives the shared builder with the golden-style arguments, overriding one at a time.
  private func withdrawCalldata(
    builder: TransactionBuilderProtocol,
    addresses: RainWithdrawAddresses = TestFixtures.defaultWithdrawAddresses,
    amount: Decimal = 100.0,
    decimals: Int = 18,
    expiresAt: String = "1735689600"
  ) throws -> String {
    try WithdrawalBuilder.buildWithdrawTransactionData(
      builder: builder,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      executorSignature: RainAdminSignature(
        salt: Data(repeating: 0x11, count: 32).base64EncodedString(),
        signature: "0x" + String(repeating: "42", count: 65),
        expiresAt: expiresAt
      ),
      walletSalt: Data(repeating: 0xAA, count: 32),
      walletSignature: "0x" + String(repeating: "bb", count: 65)
    )
  }

  /// Invalid EVM addresses surface as RAIN_102 with the offending address in the message.
  private var addressError: RainError {
    .invalidConfig(details: "Invalid address format: invalid-address")
  }

  @Test("buildWithdrawTransactionData returns mock calldata with valid inputs")
  func testBuildWithdrawTransactionDataSuccess() throws {
    let txData = try withdrawCalldata(builder: MockTransactionBuilderService(networkConfigs: TestFixtures.configs()))

    #expect(txData.hasPrefix("0x"))
    // Mock builder always returns "0x" + "a1b2c3d4" x 16
    #expect(txData == "0x" + String(repeating: "a1b2c3d4", count: 16))
  }

  @Test("buildWithdrawTransactionData throws for invalid controller address")
  func testBuildWithdrawTransactionDataInvalidControllerAddress() throws {
    let addresses = RainWithdrawAddresses(
      proxyAddress: TestFixtures.proxyAddress,
      controllerAddress: "invalid-address",
      tokenAddress: TestFixtures.tokenAddress,
      recipientAddress: TestFixtures.recipientAddress
    )

    #expect(throws: addressError) {
      try withdrawCalldata(builder: TransactionBuilderService(networkConfigs: []), addresses: addresses)
    }
  }

  @Test("buildWithdrawTransactionData throws for invalid proxy address")
  func testBuildWithdrawTransactionDataInvalidProxyAddress() throws {
    let addresses = RainWithdrawAddresses(
      proxyAddress: "invalid-address",
      controllerAddress: TestFixtures.contractAddress,
      tokenAddress: TestFixtures.tokenAddress,
      recipientAddress: TestFixtures.recipientAddress
    )

    #expect(throws: addressError) {
      try withdrawCalldata(builder: TransactionBuilderService(networkConfigs: []), addresses: addresses)
    }
  }

  @Test("buildWithdrawTransactionData throws for invalid recipient address")
  func testBuildWithdrawTransactionDataInvalidRecipientAddress() throws {
    let addresses = RainWithdrawAddresses(
      proxyAddress: TestFixtures.proxyAddress,
      controllerAddress: TestFixtures.contractAddress,
      tokenAddress: TestFixtures.tokenAddress,
      recipientAddress: "invalid-address"
    )

    #expect(throws: addressError) {
      try withdrawCalldata(builder: TransactionBuilderService(networkConfigs: []), addresses: addresses)
    }
  }

  @Test("buildWithdrawTransactionData throws for invalid expiration timestamp")
  func testBuildWithdrawTransactionDataInvalidExpiration() throws {
    #expect(throws: RainError.invalidConfig(details: "Invalid expiresAt format: invalid-timestamp. Expected a unix-seconds or ISO-8601 string.")) {
      try withdrawCalldata(
        builder: TransactionBuilderService(networkConfigs: []),
        expiresAt: "invalid-timestamp"
      )
    }
  }

  @Test("buildWithdrawTransactionData accepts ISO8601 timestamp")
  func testBuildWithdrawTransactionDataISO8601Timestamp() throws {
    let txData = try withdrawCalldata(
      builder: MockTransactionBuilderService(networkConfigs: TestFixtures.configs()),
      expiresAt: "2025-01-01T00:00:00Z"
    )

    #expect(txData.hasPrefix("0x"))
  }

  @Test("buildWithdrawTransactionData accepts 6-decimal tokens")
  func testBuildWithdrawTransactionDataDifferentDecimals() throws {
    let txData = try withdrawCalldata(
      builder: MockTransactionBuilderService(networkConfigs: TestFixtures.configs()),
      amount: 100.5,
      decimals: 6
    )

    #expect(txData.hasPrefix("0x"))
  }

  // MARK: - Live network integration

  /// Integration test: hits Avalanche Fuji RPC to read the on-chain nonce.
  /// Verifies the call succeeds, the value fits uint256, and consecutive reads are stable.
  /// Intentionally a live-network dependency, so it is env-gated: set RAIN_LIVE_TESTS=1 to run
  /// it locally. CI skips it (runners flake on TLS/egress to public RPCs).
  @Test(
    "getLatestNonce reads a stable uint256 from a live Fuji contract",
    .enabled(if: ProcessInfo.processInfo.environment["RAIN_LIVE_TESTS"] == "1")
  )
  func testGetLatestNonceFromRealContract() async throws {
    let chainId = 43113
    let contractAddress = "0x5a022623280AA5E922A4D9BB3024fA7D70D7e789"
    let builder = TransactionBuilderService(
      networkConfigs: [NetworkConfig(chainId: chainId, rpcUrl: "https://avalanche-fuji-c-chain-rpc.publicnode.com")]
    )

    let first = try await builder.getLatestNonce(proxyAddress: contractAddress, chainId: chainId)
    let second = try await builder.getLatestNonce(proxyAddress: contractAddress, chainId: chainId)

    #expect(first == second, "Consecutive nonce reads on a stable contract must be equal")
    #expect(first.bitWidth <= 256, "Nonce must fit in uint256")
  }
}

// MARK: - Test-only shims

/// The EIP-712 builder moved to ``WithdrawalBuilder``; these keep the existing cases readable by
/// driving it through the manager's own services.
private extension RainSdkManager {
  func buildEIP712MessageForTest(
    chainId: Int,
    walletAddress: String,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    nonce: BigUInt?
  ) async throws -> String {
    try await WithdrawalBuilder.buildEIP712Message(
      builder: transactionBuilderService,
      chainId: chainId,
      walletAddress: walletAddress,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      nonce: nonce
    ).message
  }

  func buildEIP712PairForTest(
    chainId: Int,
    walletAddress: String,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    nonce: BigUInt?
  ) async throws -> (String, String) {
    let built = try await WithdrawalBuilder.buildEIP712Message(
      builder: transactionBuilderService,
      chainId: chainId,
      walletAddress: walletAddress,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      nonce: nonce
    )
    return (built.message, built.saltHex)
  }
}

// MARK: - Private helpers

private func parseJSON(_ string: String) throws -> [String: Any] {
  guard let data = string.data(using: .utf8) else {
    throw NSError(domain: "TestHelpers", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON string"])
  }
  guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw NSError(domain: "TestHelpers", code: -2, userInfo: [NSLocalizedDescriptionKey: "Expected JSON object"])
  }
  return dict
}
