import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

/// Manager-level contract for the Auth Pull approval surface: what gets encoded, what gets
/// broadcast, what is read back, and which failures surface as which typed error.
/// Serialized: the fee-estimation test stubs `URLSession.shared` via `MockURLProtocol`.
@Suite("Token Approval Tests", .serialized)
struct TokenApprovalTests {

  // A sandbox Auth Pull chain: the manager defaults to the sandbox chain set, and approvals off
  // that set are rejected before anything is encoded.
  private let chainId = RainChain.baseSepolia
  private let usdc = TestFixtures.authPullUsdcAddress
  private let spender = TestFixtures.authPullOperator
  private let unknownToken = "0x000000000000000000000000000000000000dEaD"

  private var usdcInfo: TokenInfo {
    TokenInfo(chainId: chainId, address: usdc, symbol: "USDC", decimals: 6, name: "USDC")
  }

  // MARK: - approveTokenAllowance

  @Test("an omitted amount approves uint256 max")
  func omittedAmountApprovesUnlimited() async throws {
    let (manager, stub, _, builder) = TestManagers.approvalManager()
    stub.sendTransactionHashToReturn = "0xapprovalhash"

    let result = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    #expect(result.transactionHash == "0xapprovalhash")
    #expect(builder.approveCalls.count == 1)
    #expect(builder.approveCalls[0].amount == RainTokenAllowance.unlimitedRawAmount)
    #expect(builder.approveCalls[0].spender == spender)
    #expect(builder.approveCalls[0].contractAddress == usdc)
    #expect(builder.approveCalls[0].walletAddress == TestFixtures.walletAddress)
  }

  @Test("an unlimited approval needs no decimals lookup")
  func unlimitedApprovalSkipsDecimalsRead() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager()

    _ = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    #expect(reader.decimalsCalls.isEmpty)
  }

  @Test("a decimal amount is scaled by the token's decimals")
  func decimalAmountIsScaled() async throws {
    let (manager, _, _, builder) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    _ = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: Decimal(string: "250.5")!
    )

    #expect(builder.approveCalls[0].amount == BigUInt(250_500_000))
  }

  /// There is no `decimals` parameter to get this wrong with: the scale comes from trusted
  /// metadata, so a token the registry knows is never re-read and never re-scaled.
  @Test("the scale always comes from trusted metadata")
  func scaleComesFromTrustedMetadata() async throws {
    let reader = MockChainReader()
    reader.stubbedDecimals = 18
    let (manager, _, _, builder) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader
    )

    _ = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 1
    )

    // 1 USDC at the registry's 6 decimals, not 10^18.
    #expect(builder.approveCalls[0].amount == BigUInt(1_000_000))
    #expect(reader.decimalsCalls.isEmpty)
  }

  @Test("a zero amount is a revoke, not an invalid amount")
  func zeroAmountRevokes() async throws {
    let (manager, _, _, builder) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    let result = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 0
    )

    #expect(builder.approveCalls[0].amount == 0)
    #expect(!result.transactionHash.isEmpty)
  }

  @Test("the approval is sent to the token contract with zero value")
  func approvalTargetsTheTokenContract() async throws {
    let (manager, stub, _, builder) = TestManagers.approvalManager()
    builder.stubbedApproveData = "0x095ea7b3deadbeef"

    _ = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    let sent = try #require(stub.sendTransactionCalls.first)
    #expect(sent.chainId == chainId)
    #expect(sent.params.to == usdc)
    #expect(sent.params.data == "0x095ea7b3deadbeef")
    #expect(sent.params.from == TestFixtures.walletAddress)
    #expect(BigUInt(sent.params.value.strippingHexPrefix, radix: 16) == 0)
  }

  // MARK: - Validation

  @Test("a negative amount is rejected before any provider call")
  func negativeAmountRejected() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    await #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: -1
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("an amount finer than the token's scale is rejected, not truncated")
  func overPreciseAmountRejected() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    await #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: Decimal(string: "1.2345678")!
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a malformed spender is rejected before any provider call")
  func malformedSpenderRejected() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: "not-an-address"
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a malformed token contract is rejected before any provider call")
  func malformedContractRejected() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: "0x1234",
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a non-positive chain id is rejected")
  func invalidChainIdRejected() async throws {
    let (manager, _, _, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: 0,
        contractAddress: usdc,
        spender: spender
      )
    }
  }

  @Test("a Solana chain id is rejected instead of taking the EVM path")
  func solanaChainIdRejected() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.solanaDevnet,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  // MARK: - Environment / chain pairing

  @Test("a production chain is rejected on a sandbox-configured client")
  func productionChainRejectedInSandbox() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()

    // Base mainnet is an Auth Pull chain, but not this environment's — approving here would mine a
    // real mainnet allowance for the sandbox operator.
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.baseMainnet,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a sandbox chain is rejected on a production-configured client")
  func sandboxChainRejectedInProduction() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager(
      authPullChainIds: RainAuthPullChains.production
    )

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.baseSepolia,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a non-Auth-Pull chain is rejected even though it is a valid EVM chain")
  func nonAuthPullChainRejected() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: 1,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("the allowance read applies the same environment gate")
  func allowanceReadAppliesEnvironmentGate() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.getTokenAllowance(
        chainId: RainChain.baseMainnet,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(reader.allowanceCalls.isEmpty)
  }

  @Test("every production Auth Pull chain is accepted on a production client")
  func productionChainsAcceptedInProduction() async throws {
    for chain in RainAuthPullChains.production {
      let token = try #require(TestFixtures.authPullTokens(for: [chain])[chain])
      let (manager, stub, _, _) = TestManagers.approvalManager(
        configs: TestFixtures.configs(chainId: chain, rpcUrl: "https://rpc.test"),
        authPullChainIds: RainAuthPullChains.production
      )
      stub.sendTransactionHashToReturn = "0xok"

      let result = try await manager.approveTokenAllowance(
        chainId: chain,
        contractAddress: token,
        spender: spender
      )

      #expect(result.transactionHash == "0xok")
    }
  }

  // MARK: - Trusted targets

  @Test("Auth Pull is refused entirely until it is configured")
  func unconfiguredClientRefusesApprovals() async throws {
    let manager = TestManagers.authPullDisabledManager()

    #expect(manager.authPullChainIds.isEmpty)
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.getTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
  }

  /// `approve` succeeds against any address and needs no balance, so an approval naming the wrong
  /// spender mines a real allowance that nothing downstream would ever flag.
  @Test("a valid but untrusted spender is rejected before any provider call")
  func untrustedSpenderRejected() async throws {
    let (manager, stub, _, builder) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: "0x1111111111111111111111111111111111111111"
      )
    }
    #expect(builder.approveCalls.isEmpty)
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a valid but untrusted token is rejected before any provider call")
  func untrustedTokenRejected() async throws {
    let (manager, stub, _, builder) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: unknownToken,
        spender: spender
      )
    }
    #expect(builder.approveCalls.isEmpty)
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("the trusted target is matched case-insensitively, not byte-for-byte")
  func trustedTargetIgnoresChecksumCasing() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()
    stub.sendTransactionHashToReturn = "0xok"

    let result = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: usdc.lowercased(),
      spender: spender.lowercased()
    )

    #expect(result.transactionHash == "0xok")
  }

  /// The set a host gates its UI on has to be the same set the guard enforces. Asserted as one
  /// fact rather than two: every advertised chain approves, and no unadvertised one does.
  @Test("the advertised chain set is exactly what the guard accepts")
  func advertisedChainSetMatchesTheGuard() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager(
      authPullChainIds: [RainChain.baseSepolia]
    )
    stub.sendTransactionHashToReturn = "0xok"

    #expect(manager.authPullChainIds == [RainChain.baseSepolia])

    _ = try await manager.approveTokenAllowance(
      chainId: RainChain.baseSepolia,
      contractAddress: usdc,
      spender: spender
    )
    #expect(stub.sendTransactionCalls.count == 1)

    // Arbitrum Sepolia is an Auth Pull chain for this environment, but not for this client.
    #expect(RainAuthPullChains.sandbox.contains(RainChain.arbitrumSepolia))
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: RainChain.arbitrumSepolia,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.count == 1)
  }

  // MARK: - confirmTokenAllowance

  @Test("confirmation requires a successful receipt and returns the resulting allowance")
  func confirmationReturnsMinedAllowance() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatus = true
    reader.stubbedAllowance = BigUInt(250_000_000)

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "a", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 250
    )

    #expect(allowance.rawAmount == BigUInt(250_000_000))
  }

  /// Auth Pull spends the very allowance being confirmed, so a value below the approved one is an
  /// ordinary outcome — the authorization got there first. Confirming must not call that a failure.
  @Test("an allowance already partly pulled still confirms")
  func partlyPulledAllowanceStillConfirms() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatus = true
    reader.stubbedAllowance = BigUInt(100_000_000)

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "c", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 250
    )

    #expect(allowance.rawAmount == BigUInt(100_000_000))
  }

  /// USDC decrements even a `uint256` max allowance on every `transferFrom`.
  @Test("an unlimited approval confirms after a pull decremented it")
  func decrementedUnlimitedAllowanceConfirms() async throws {
    let decremented = RainTokenAllowance.unlimitedRawAmount - BigUInt(1_000_000)
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatus = true
    reader.stubbedAllowance = decremented

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "d", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    #expect(allowance.rawAmount == decremented)
    #expect(!allowance.isUnlimited)
  }

  @Test("a revoke that left a spendable allowance fails")
  func revokeLeavingAllowanceFails() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatus = true
    reader.stubbedAllowance = BigUInt(500)

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "e", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 0
      )
    }
  }

  @Test("an approval that mined against a still-zero allowance fails")
  func approvalMinedAgainstZeroFails() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatus = true
    reader.stubbedAllowance = 0

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "f", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 250
      )
    }
  }

  @Test("confirmation polls until the receipt appears")
  func confirmationPollsUntilMined() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatuses = [nil, true]
    reader.stubbedAllowance = BigUInt(250_000_000)

    _ = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "1", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 250
    )

    #expect(reader.receiptCalls.count == 2)
    #expect(reader.allowanceCalls.count == 1)
  }

  // MARK: - Confirmation reads the transaction's own block
  //
  // `stubbedAllowanceByBlock` is the state at the receipt's block, `stubbedAllowance` what a lagging
  // node answers — so reading at `latest` fails these with the exact production error, both ways.

  @Test("an approval is confirmed against the block it mined in, not against a lagging head")
  func confirmationReadsAtReceiptBlock() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = true
    reader.stubbedReceiptBlockNumber = "0x2a"
    reader.stubbedAllowance = 0 // what a node that is still behind would answer
    reader.stubbedAllowanceByBlock = ["0x2a": BigUInt(10_000_000)]
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader
    )

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "2", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 10
    )

    #expect(allowance.rawAmount == BigUInt(10_000_000))
    #expect(reader.allowanceCalls.count == 1)
    #expect(reader.allowanceCalls[0].atBlock == "0x2a")
  }

  /// The dangerous direction: a stale zero looks like a successful revoke that never landed.
  @Test("a revoke is confirmed against its own block rather than a stale zero")
  func revokeConfirmsAtReceiptBlock() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = true
    reader.stubbedReceiptBlockNumber = "0x2a"
    // A node one block behind still shows the pre-revoke allowance.
    reader.stubbedAllowance = BigUInt(10_000_000)
    reader.stubbedAllowanceByBlock = ["0x2a": 0]
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader
    )

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "3", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 0
    )

    #expect(allowance.isZero)
    #expect(reader.allowanceCalls[0].atBlock == "0x2a")
  }

  /// A node without the receipt's block errors; that is a retry, not a verdict.
  @Test("a node that has not reached the receipt block yet is retried")
  func laggingNodeIsRetried() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = true
    reader.stubbedReceiptBlockNumber = "0x2a"
    reader.stubbedAllowanceByBlock = ["0x2a": BigUInt(10_000_000)]
    reader.stubbedAllowanceFailures = [
      RainError.internalError(details: "RPC error [-32000]: header not found")
    ]
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader
    )

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "4", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 10
    )

    #expect(allowance.rawAmount == BigUInt(10_000_000))
    #expect(reader.allowanceCalls.count == 2)
    // The receipt is not re-fetched once it is in hand — only the read is retried.
    #expect(reader.receiptCalls.count == 1)
  }

  /// A mismatch at the transaction's own block is final; retrying only delays the same answer.
  @Test("a verdict from the pinned block is not retried")
  func pinnedBlockVerdictIsFinal() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = true
    reader.stubbedReceiptBlockNumber = "0x2a"
    reader.stubbedAllowanceByBlock = ["0x2a": 0]
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader
    )

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "5", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 10
      )
    }
    #expect(reader.allowanceCalls.count == 1)
  }

  // MARK: - Confirmation survives node blips and reports the right thing on timeout

  /// The approval is already out: one failed receipt read is a retry, not a hard error.
  @Test("a receipt read that fails mid-poll is retried")
  func receiptReadFailureIsRetried() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = true
    reader.stubbedAllowance = BigUInt(250_000_000)
    reader.stubbedReceiptFailures = [URLError(.networkConnectionLost)]
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader,
      approvalConfirmationInterval: .milliseconds(1)
    )

    let allowance = try await manager.confirmTokenAllowance(
      transactionHash: "0x" + String(repeating: "6", count: 64),
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      amount: 250
    )

    #expect(allowance.rawAmount == BigUInt(250_000_000))
    #expect(reader.receiptCalls.count == 2)
    #expect(reader.allowanceCalls.count == 1)
  }

  /// A malformed hash is a verdict on the input, not a node blip: it must not burn the window.
  @Test("an invalid hash is rejected at once rather than retried for the whole window")
  func invalidHashIsNotRetried() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptFailures = [RainError.invalidConfig(details: "Invalid transaction hash")]
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader,
      approvalConfirmationInterval: .milliseconds(1)
    )

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "7", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 250
      )
    }
    #expect(reader.receiptCalls.count == 1)
  }

  /// Not mined by the end of the window is pending, not failure: the host resumes from the hash
  /// (re-read or confirm again) instead of re-approving.
  @Test("an approval that never mines surfaces as transactionPending carrying the hash")
  func unminedApprovalIsPending() async throws {
    let hash = "0x" + String(repeating: "8", count: 64)
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = nil
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader,
      approvalConfirmationInterval: .milliseconds(1)
    )

    do {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: hash,
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 250
      )
      Issue.record("expected transactionPending")
    } catch RainError.transactionPending(let statusId) {
      #expect(statusId == hash)
    }
    #expect(reader.receiptCalls.count == RainSdkManager.ApprovalConfirmation.attempts)
    #expect(reader.allowanceCalls.isEmpty)
  }

  /// Receipt reads that fail for the whole window are still pending, not a network verdict.
  @Test("receipt reads that keep failing end in transactionPending, not networkError")
  func persistentReceiptFailuresEndPending() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptError = URLError(.timedOut)
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader,
      approvalConfirmationInterval: .milliseconds(1)
    )

    await #expect(throws: RainError.transactionPending(statusId: "")) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "9", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 250
      )
    }
    #expect(reader.receiptCalls.count == RainSdkManager.ApprovalConfirmation.attempts)
  }

  /// A host that cancels a confirm mid-poll must see the cancellation, never a pending or network
  /// error dressed up from it.
  @Test("cancelling a confirm mid-poll propagates the cancellation, not a timeout")
  func cancellationPropagates() async throws {
    let reader = MockChainReader()
    reader.stubbedReceiptStatus = nil
    let (manager, _, _, _) = TestManagers.approvalManager(
      registeredTokens: [usdcInfo],
      reader: reader,
      approvalConfirmationInterval: .milliseconds(50)
    )
    let (chainId, usdc, spender) = (chainId, usdc, spender)

    let task = Task {
      try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "c", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        amount: 250
      )
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(reader.receiptCalls.count < RainSdkManager.ApprovalConfirmation.attempts)
  }

  @Test("confirmation rejects a reverted receipt without reading the allowance")
  func confirmationRejectsRevertedReceipt() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedReceiptStatus = false

    await #expect(throws: RainError.transactionSimulationFailed(underlying: RainError.walletUnavailable())) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "b", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(reader.allowanceCalls.isEmpty)
  }

  @Test("confirmation applies the same trusted-target guard as the approval")
  func confirmationValidatesTargets() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.confirmTokenAllowance(
        transactionHash: "0x" + String(repeating: "a", count: 64),
        chainId: chainId,
        contractAddress: usdc,
        spender: "0x1111111111111111111111111111111111111111"
      )
    }
    #expect(reader.receiptCalls.isEmpty)
  }

  // MARK: - Provider failures

  @Test("a user rejection in the wallet surfaces as userRejected")
  func userRejectionPropagates() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()
    stub.sendTransactionError = RainError.userRejected

    await #expect(throws: RainError.userRejected) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
  }

  @Test("a simulation revert keeps its own code rather than the withdrawal one")
  func simulationFailurePropagates() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()
    stub.sendTransactionError = RainError.transactionSimulationFailed(
      underlying: RainError.internalError(details: "reverted")
    )

    let error = await #expect(throws: RainError.self) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(error?.code == "RAIN_403")
  }

  @Test("an encoding failure surfaces as a typed SDK error")
  func encodingFailurePropagates() async throws {
    let (manager, stub, _, builder) = TestManagers.approvalManager()
    builder.stubbedApproveError = RainError.internalError(details: "Failed to encode ERC-20 approve")

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a provider error is wrapped, never leaked as a raw vendor error")
  func providerErrorIsWrapped() async throws {
    struct VendorError: Error {}
    let (manager, stub, _, _) = TestManagers.approvalManager()
    stub.sendTransactionError = VendorError()

    let error = await #expect(throws: RainError.self) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
    // Classified as a provider failure, not passed through as the vendor's own type.
    #expect(error?.code == "RAIN_501")
  }

  /// The one error the wrap must never touch: a cancelled send is the caller walking away, and
  /// RAIN_501 would tell them it settled as failed.
  @Test("a cancelled send is not wrapped as a provider failure")
  func cancellationIsNotWrapped() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()
    stub.sendTransactionError = CancellationError()

    await #expect(throws: CancellationError.self) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
  }

  // MARK: - getTokenAllowance

  @Test("the allowance is read for the wallet's own address by default")
  func allowanceDefaultsToOwnWallet() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedAllowance = BigUInt(250_000_000)

    let allowance = try await manager.getTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    // A standalone read has no transaction to pin to, so `latest` is the right block here —
    // unlike a confirmation, which reads at the block its transaction mined in.
    #expect(reader.allowanceCalls == [
      MockChainReader.AllowanceCall(
        chainId: chainId,
        tokenAddress: usdc,
        owner: TestFixtures.walletAddress,
        spender: spender,
        atBlock: "latest"
      )
    ])
    #expect(allowance.rawAmount == BigUInt(250_000_000))
    #expect(allowance.decimals == 6)
    #expect(allowance.decimalAmount == Decimal(250))
    #expect(allowance.formatted == "250")
    #expect(!allowance.isUnlimited)
    #expect(!allowance.isZero)
  }

  @Test("an explicit owner is read instead of the wallet's own address")
  func allowanceReadsExplicitOwner() async throws {
    let other = "0x3cA8ac240F6ebeA8684b3E629A8e8C1f0E3bC0Ff"
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    _ = try await manager.getTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender,
      owner: other
    )

    #expect(reader.allowanceCalls[0].owner == other)
  }

  @Test("a malformed explicit owner is rejected before the chain read")
  func malformedOwnerRejected() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.getTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender,
        owner: "0xnope"
      )
    }
    #expect(reader.allowanceCalls.isEmpty)
  }

  @Test("an unlimited allowance is exact in rawAmount even though the display value rounds")
  func unlimitedAllowanceStaysExactInRawAmount() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedAllowance = RainTokenAllowance.unlimitedRawAmount

    let allowance = try await manager.getTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    #expect(allowance.isUnlimited)
    #expect(allowance.rawAmount == RainTokenAllowance.unlimitedRawAmount)
    // `Decimal` holds 38 significant digits, so the 78-digit display value is rounded — lossy,
    // but not nil and not NaN. `covers` must answer from rawAmount regardless.
    #expect(!allowance.decimalAmount.isNaN)
    #expect(allowance.decimalAmount > Decimal(string: "1e70")!)
    #expect(allowance.covers(1_000_000))
  }

  @Test("a zero allowance is reported as revoked and covers nothing")
  func zeroAllowanceCoversNothing() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedAllowance = 0

    let allowance = try await manager.getTokenAllowance(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    #expect(allowance.isZero)
    #expect(allowance.decimalAmount == 0)
    #expect(!allowance.covers(Decimal(string: "0.000001")!))
    #expect(allowance.covers(0))
  }

  @Test("covers compares against the exact base units the amount needs")
  func coversComparesBaseUnits() {
    let allowance = RainTokenAllowance(
      chainId: chainId,
      tokenAddress: usdc,
      owner: TestFixtures.walletAddress,
      spender: spender,
      rawAmount: BigUInt(250_000_000),
      decimals: 6
    )

    #expect(allowance.covers(250))
    #expect(allowance.covers(Decimal(string: "249.999999")!))
    #expect(!allowance.covers(Decimal(string: "250.000001")!))
    // Finer than the token's scale can't be represented, so it isn't covered.
    #expect(!allowance.covers(Decimal(string: "0.0000001")!))
  }

  @Test("an unresolvable decimals refuses to guess rather than over-approving")
  func unknownDecimalsRefusesToGuess() async throws {
    // Not in the registry, and `decimals()` reverts. Guessing 18 against a 6-decimal token would
    // approve 10^12 times the requested amount, and `approve` has no balance to fail against.
    let (manager, stub, reader, builder) = TestManagers.approvalManager(
      authPullTokenAddresses: [RainChain.baseSepolia: unknownToken]
    )
    reader.stubbedMetadataError = RainError.networkError(
      underlying: RainError.internalError(details: "rpc down")
    )

    await #expect(throws: RainError.tokenNotFound(token: "", chainId: 0)) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: unknownToken,
        spender: spender,
        amount: 250
      )
    }
    #expect(builder.approveCalls.isEmpty)
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("an unlimited approval still needs no decimals, even for an unknown token")
  func unlimitedApprovalSurvivesUnknownDecimals() async throws {
    let (manager, _, reader, builder) = TestManagers.approvalManager(
      authPullTokenAddresses: [RainChain.baseSepolia: unknownToken]
    )
    reader.stubbedMetadataError = RainError.networkError(
      underlying: RainError.internalError(details: "rpc down")
    )

    _ = try await manager.approveTokenAllowance(
      chainId: chainId,
      contractAddress: unknownToken,
      spender: spender
    )

    #expect(builder.approveCalls[0].amount == RainTokenAllowance.unlimitedRawAmount)
  }

  @Test("an allowance read refuses to report a scale it had to guess")
  func allowanceReadRefusesGuessedDecimals() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(
      authPullTokenAddresses: [RainChain.baseSepolia: unknownToken]
    )
    reader.stubbedAllowance = BigUInt(250_000_000)
    reader.stubbedMetadataError = RainError.networkError(
      underlying: RainError.internalError(details: "rpc down")
    )

    await #expect(throws: RainError.tokenNotFound(token: "", chainId: 0)) {
      _ = try await manager.getTokenAllowance(
        chainId: chainId,
        contractAddress: unknownToken,
        spender: spender
      )
    }
  }

  @Test("absurd decimals are rejected instead of trapping on the Int16 conversion")
  func absurdDecimalsRejected() async throws {
    let reader = MockChainReader()
    reader.stubbedDecimals = 40_000
    let (manager, stub, _, _) = TestManagers.approvalManager(
      authPullTokenAddresses: [RainChain.baseSepolia: unknownToken],
      reader: reader
    )

    // 40_000 overflows Int16, which the scaling math would trap on — a crash, not an error.
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.approveTokenAllowance(
        chainId: chainId,
        contractAddress: unknownToken,
        spender: spender,
        amount: 1
      )
    }
    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("a token reporting absurd decimals cannot crash the allowance read either")
  func absurdDecimalsRejectedOnRead() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(
      authPullTokenAddresses: [RainChain.baseSepolia: unknownToken]
    )
    reader.stubbedAllowance = BigUInt(1)
    reader.stubbedDecimals = 40_000

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.getTokenAllowance(
        chainId: chainId,
        contractAddress: unknownToken,
        spender: spender
      )
    }
  }

  @Test("a failed allowance read surfaces as a typed SDK error")
  func allowanceReadFailurePropagates() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager(registeredTokens: [usdcInfo])
    reader.stubbedAllowanceError = RainError.networkError(
      underlying: RainError.internalError(details: "boom")
    )

    await #expect(throws: RainError.networkError(underlying: RainError.walletUnavailable())) {
      _ = try await manager.getTokenAllowance(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
  }

  @Test("a Solana chain id is rejected on the allowance read too")
  func allowanceRejectsSolana() async throws {
    let (manager, _, reader, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.getTokenAllowance(
        chainId: RainChain.solanaDevnet,
        contractAddress: usdc,
        spender: spender
      )
    }
    #expect(reader.allowanceCalls.isEmpty)
  }

  // MARK: - estimateApprovalFee

  @Test("fee estimation broadcasts nothing")
  func feeEstimationDoesNotBroadcast() async throws {
    let (manager, stub, _, _) = TestManagers.approvalManager()

    // The stub provider cannot estimate fees, so this throws — the point is that it never
    // reached `sendTransaction` on the way there.
    _ = try? await manager.estimateApprovalFee(
      chainId: chainId,
      contractAddress: usdc,
      spender: spender
    )

    #expect(stub.sendTransactionCalls.isEmpty)
  }

  @Test("fee estimation on a provider that cannot estimate throws internalError")
  func feeEstimationUnsupportedProvider() async throws {
    let (manager, _, _, _) = TestManagers.approvalManager()

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.estimateApprovalFee(
        chainId: chainId,
        contractAddress: usdc,
        spender: spender
      )
    }
  }

  @Test("fee estimation applies the same validation as the approval")
  func feeEstimationValidates() async throws {
    let (manager, _, _, builder) = TestManagers.approvalManager()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await manager.estimateApprovalFee(
        chainId: chainId,
        contractAddress: usdc,
        spender: "0xnope"
      )
    }
    #expect(builder.approveCalls.isEmpty)
  }
}
