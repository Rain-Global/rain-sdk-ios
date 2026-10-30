import Testing
import Foundation
import TurnkeySwift
import TurnkeyTypes
import Web3
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// Turnkey's managed-broadcast registry: which chains a send may leave on at all.
@Suite("Turnkey Broadcast Chains")
struct TurnkeyBroadcastChainsTests {

  @Test("Turnkey's covered EVM networks and both Solana clusters it broadcasts on are sendable",
        arguments: [1, 8453, 137, 42161, 10, 56, 11155111, 84532, 80002, 421614,
                    RainChain.solanaMainnet, RainChain.solanaDevnet])
  func coveredChains(chainId: Int) throws {
    #expect(TurnkeyBroadcastChains.supportsSend(chainId: chainId))
    try TurnkeyBroadcastChains.requireSendSupport(chainId: chainId)
  }

  @Test("chains outside Turnkey's broadcast list are refused — Avalanche, Solana testnet",
        arguments: [43114, 43113, RainChain.solanaTestnet, 999_999])
  func uncoveredChains(chainId: Int) {
    #expect(!TurnkeyBroadcastChains.supportsSend(chainId: chainId))
    #expect(throws: RainError.chainNotSupported(chainId: chainId, details: "")) {
      try TurnkeyBroadcastChains.requireSendSupport(chainId: chainId)
    }
  }

  @Test("the refusal names the chain and carries RAIN_104")
  func errorShape() {
    do {
      try TurnkeyBroadcastChains.requireSendSupport(chainId: 43114)
      Issue.record("Expected chainNotSupported")
    } catch let error as RainError {
      #expect(error.code == "RAIN_104")
      #expect(error.errorDescription?.contains("43114") == true)
    } catch {
      Issue.record("Expected RainError, got \(error)")
    }
  }
}

/// Gas sponsorship and send gating on the Turnkey adapter, driven through `RainSdkManager`.
/// Stubs that use `MockURLProtocol` run serialized (global registration).
@Suite("Turnkey Sponsorship & Send Gating", .serialized)
struct TurnkeySponsorshipTests {

  // MARK: - Capabilities

  @Test("the descriptor and the resolved wallet advertise gasSponsorship only when sponsorGas is on")
  func capabilitiesFollowTheFlag() {
    #expect(TurnkeyWalletProviderAdapter.capabilities(sponsorGas: true)
      == [.export, .multiChain, .gasSponsorship])
    #expect(TurnkeyWalletProviderAdapter.capabilities(sponsorGas: false)
      == [.export, .multiChain])
  }

  @Test("sponsorship applies exactly where Turnkey can broadcast")
  func sponsorsFeesIsPerChain() {
    let sponsored = TurnkeyWalletProviderAdapter(
      turnkey: MockTurnkey(), networkConfigs: TestFixtures.configs(), sponsorGas: true,
      chainReader: MockChainReader()
    )
    #expect(sponsored.sponsorsFees(chainId: 1))
    #expect(sponsored.sponsorsFees(chainId: RainChain.solanaMainnet))
    #expect(!sponsored.sponsorsFees(chainId: 43114)) // read-only chain: nobody sponsors a send that can't happen

    let selfPaid = TurnkeyWalletProviderAdapter(
      turnkey: MockTurnkey(), networkConfigs: TestFixtures.configs(), sponsorGas: false,
      chainReader: MockChainReader()
    )
    #expect(!selfPaid.sponsorsFees(chainId: 1))
  }

  @Test("rent is sponsored only on a Solana chain Turnkey broadcasts to, with both flags on")
  func sponsorsRentNeedsBothFlagsAndSolana() {
    func adapter(sponsorGas: Bool, sponsorRent: Bool) -> TurnkeyWalletProviderAdapter {
      TurnkeyWalletProviderAdapter(
        turnkey: MockTurnkey(), networkConfigs: TestFixtures.configs(),
        sponsorGas: sponsorGas, sponsorRent: sponsorRent, chainReader: MockChainReader()
      )
    }
    let both = adapter(sponsorGas: true, sponsorRent: true)
    #expect(both.sponsorsRent(chainId: RainChain.solanaMainnet))
    #expect(both.sponsorsRent(chainId: RainChain.solanaDevnet))
    #expect(!both.sponsorsRent(chainId: RainChain.solanaTestnet), "not a broadcast cluster")
    #expect(!both.sponsorsRent(chainId: 1), "rent is a Solana concept")

    #expect(!adapter(sponsorGas: false, sponsorRent: true).sponsorsRent(chainId: RainChain.solanaMainnet),
            "rent is pre-funded inside a sponsored send only")
    #expect(!adapter(sponsorGas: true, sponsorRent: false).sponsorsRent(chainId: RainChain.solanaMainnet))
  }

  // MARK: - Sponsored EVM send

  @Test("a sponsored send is a minimal payload carrying the gas-station nonce, with no chain RPC")
  func sponsoredSendBody() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.mockGasStationNonce = "42"
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0x" + String(repeating: "8", count: 64))]

    // No RPC stubs installed: a sponsored send must not touch eth_getTransactionCount,
    // eth_estimateGas or eth_gasPrice (a zero-balance wallet has nothing to estimate against).
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey, sponsorGas: true)
    _ = try await manager.sendNative(chainId: 1, to: TestFixtures.recipientAddress, amount: 1.0)

    let body = try #require(client.ethSendTransactionCalls.first)
    #expect(body.sponsor == true)
    #expect(body.gasStationNonce == "42")
    #expect(body.nonce == nil)
    #expect(body.gasLimit == nil)
    #expect(body.maxFeePerGas == nil)
    #expect(body.maxPriorityFeePerGas == nil)
    #expect(body.caip2 == "eip155:1")

    let nonceRequest = try #require(client.getNoncesCalls.first)
    #expect(nonceRequest.gasStationNonce == true)
    #expect(nonceRequest.caip2 == "eip155:1")
    #expect(nonceRequest.address == MockTurnkey.defaultWalletAddress)
  }

  @Test("a self-paid send still pins its own nonce and gas quotes")
  func selfPaidSendBody() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_getTransactionCount", result: "0x1")
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208")
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800")

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0x" + String(repeating: "8", count: 64))]

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey, sponsorGas: false)
    _ = try await manager.sendNative(chainId: 1, to: TestFixtures.recipientAddress, amount: 1.0)

    let body = try #require(client.ethSendTransactionCalls.first)
    #expect(body.sponsor == false)
    #expect(body.gasStationNonce == nil)
    #expect(body.nonce == "1")
    #expect(client.getNoncesCalls.isEmpty)
  }

  // MARK: - Fee estimates

  @Test("estimateGas quotes the chain's cost even on a sponsored chain — what the user saves",
        arguments: [true, false])
  func estimateQuotesChainCostRegardlessOfSponsorship(sponsorGas: Bool) async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208")     // 21_000 gas
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800")   // 20 gwei

    let (manager, _, _) = TestManagers.turnkeyManager(sponsorGas: sponsorGas)
    let fee = try await manager.estimateGas(
      chainId: 1, from: MockTurnkey.defaultWalletAddress, to: TestFixtures.recipientAddress, data: "0x"
    )
    #expect(fee == Decimal(string: "0.00042")) // 21_000 * 20 gwei
  }

  // MARK: - Sponsored sends skip the dry run: the revert must still surface as a revert

  @Test("a sponsored withdrawal the contract rejects surfaces as withdrawalRevertedByNetwork, not providerError")
  func sponsoredWithdrawalRevertIsClassified() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.revertedOnChain(message: "InsufficientCollateral()")]
    let (manager, _, builder) = TestManagers.turnkeyManager(turnkey: mockTurnkey, sponsorGas: true)
    builder.mockNonce = BigUInt(42)

    await #expect(throws: RainError.withdrawalRevertedByNetwork()) {
      _ = try await manager.withdrawCollateral(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature(),
        nonce: nil
      )
    }
  }

  @Test("a failed status WITHOUT a decoded revert stays a providerError")
  func nonRevertFailureStaysProviderError() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.failed(message: "rejected by policy")]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey, sponsorGas: true)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.sendNative(chainId: 1, to: TestFixtures.recipientAddress, amount: 1.0)
    }
  }

  @Test("sendFailure classifies EVM and Solana revert details, and nothing else")
  func sendFailureClassification() {
    func status(_ fixture: MockTurnkeyClient.StatusFixture) -> TGetSendTransactionStatusResponse {
      MockTurnkeyClient.statusResponse(fixture)
    }
    #expect(TurnkeyWalletProviderAdapter.sendFailure(from: status(.broadcasted(hash: "0xaa")), fallbackMessage: "f") == nil)
    #expect(TurnkeyWalletProviderAdapter.sendFailure(from: status(.pending()), fallbackMessage: "f") == nil)

    let plain = TurnkeyWalletProviderAdapter.sendFailure(from: status(.failed()), fallbackMessage: "f")
    #expect(plain?.caseIdentifier == "providerError")

    let evm = TurnkeyWalletProviderAdapter.sendFailure(from: status(.revertedOnChain()), fallbackMessage: "f")
    #expect(evm?.caseIdentifier == "transactionSimulationFailed")

    let sol = TurnkeyWalletProviderAdapter.sendFailure(from: status(.solanaRevertedOnChain()), fallbackMessage: "f")
    #expect(sol?.caseIdentifier == "transactionSimulationFailed")
  }

  @Test("a Solana lamport shortfall in a failed status is insufficientFunds, with the System Program's amounts when it logged them")
  func sendFailureSolanaShortfall() {
    func status(_ fixture: MockTurnkeyClient.StatusFixture) -> TGetSendTransactionStatusResponse {
      MockTurnkeyClient.statusResponse(fixture)
    }

    let runtime = TurnkeyWalletProviderAdapter.sendFailure(
      from: status(.solanaLamportShortfall(transactionErrorJson: #"{"InsufficientFundsForRent":{"account_index":1}}"#)),
      fallbackMessage: "f"
    )
    #expect(runtime == .insufficientFunds(required: "", available: ""))

    let transfer = TurnkeyWalletProviderAdapter.sendFailure(
      from: status(.solanaLamportShortfall(
        transactionErrorJson: #"{"InstructionError":[0,{"Custom":1}]}"#,
        logs: [
          "Program ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL invoke [1]",
          "Program 11111111111111111111111111111111 invoke [2]",
          "Transfer: insufficient lamports 0, need 1488440",
          "Program 11111111111111111111111111111111 failed: custom program error: 0x1",
        ]
      )),
      fallbackMessage: "f"
    )
    guard case .insufficientFunds(let required, let available) = transfer else {
      Issue.record("expected insufficientFunds, got \(String(describing: transfer))")
      return
    }
    #expect(required == "0.00148844")
    #expect(available == "0")

    let revert = TurnkeyWalletProviderAdapter.sendFailure(
      from: status(.solanaLamportShortfall(
        transactionErrorJson: #"{"InstructionError":[0,{"Custom":1}]}"#,
        logs: ["Program log: Transfer: insufficient lamports 0, need 1488440"]
      )),
      fallbackMessage: "f"
    )
    #expect(revert?.caseIdentifier == "transactionSimulationFailed")
  }

  // MARK: - Send gating

  @Test("sends on a chain Turnkey cannot broadcast on fail closed before any Turnkey call",
        arguments: [true, false])
  func unsupportedChainSendRefused(sponsorGas: Bool) async throws {
    let configs = [NetworkConfig.testConfig(chainId: 43114)] // Avalanche: readable, not sendable
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let (manager, _, _) = TestManagers.turnkeyManager(
      turnkey: mockTurnkey, configs: configs, sponsorGas: sponsorGas
    )

    await #expect(throws: RainError.chainNotSupported(chainId: 43114, details: "")) {
      _ = try await manager.sendNative(chainId: 43114, to: TestFixtures.recipientAddress, amount: 1.0)
    }
    #expect(client.ethSendTransactionCalls.isEmpty)
    #expect(client.getNoncesCalls.isEmpty)
  }

  @Test("a withdrawal on an unsupported chain is refused by core before the contract reads")
  func unsupportedChainWithdrawalRefused() async throws {
    let configs = [NetworkConfig.testConfig(chainId: 43114)]
    let (manager, _, builder) = TestManagers.turnkeyManager(configs: configs)

    await #expect(throws: RainError.chainNotSupported(chainId: 43114, details: "")) {
      _ = try await manager.withdrawCollateral(
        chainId: 43114,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 1,
        decimals: 6,
        adminSignature: TestFixtures.adminSignature(),
        nonce: nil
      )
    }
    // Refused at the gate — the nonce read that starts a withdrawal never happened.
    #expect(builder.getLatestNonceCallCount == 0)
  }

  @Test("reads on an unsupported chain are not gated: balances still work on Avalanche")
  func readsUngated() async throws {
    let configs = [NetworkConfig.testConfig(chainId: 43114)]
    let reader = MockChainReader()
    reader.stubbedSingleBalance = Balance(
      token: .native, chainId: 43114, rawAmount: BigUInt(1_000_000_000_000_000_000), decimals: 18, symbol: "AVAX"
    )
    let adapter = TurnkeyWalletProviderAdapter(
      turnkey: MockTurnkey(), networkConfigs: configs, sponsorGas: true, chainReader: reader
    )

    let balance = try await adapter.getBalance(chainId: 43114, token: .native)
    #expect(balance.symbol == "AVAX")
  }
}
