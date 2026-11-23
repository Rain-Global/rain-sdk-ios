import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

/// Tests for the EVM chain-read layer.
/// Stubs `URLSession.shared` via `MockURLProtocol` — must run serialized.
@Suite("EVM ChainReader Tests", .serialized)
struct EVMChainReaderTests {

  private let walletAddress = "0x1234567890123456789012345678901234567890"
  private let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  private let daiAddress = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
  /// A collateral contract — the allowance spender.
  private let spenderAddress = "0x5a6E6b0d5Ea051CfFF9b3dcC2Aa8Dac226458f29"
  private let rpcUrl = "https://mainnet.infura.io/v3/test"
  private let txHash = "0x" + String(repeating: "ab", count: 32)
  /// Chain ID in `Multicall3.deployments` at the canonical address — picks the Multicall3 path.
  private let canonicalChainId = 1
  /// Chain ID not in `Multicall3.deployments` — picks the parallel path.
  private let nonCanonicalChainId = 11_155_111 // Sepolia (testnet; not in production allowlist)

  private func makeReader(chainId: Int = 1) -> EVMChainReader {
    let config = NetworkConfig.testConfig(chainId: chainId, rpcUrl: rpcUrl)
    return EVMChainReader(networkConfigResolver: { id in
      id == chainId ? config : nil
    })
  }

  // MARK: - Single-result methods

  @Test("getNativeBalance reads eth_getBalance and divides by 18 decimals")
  func testGetNativeBalance() async throws {
    try await MockURLProtocol.withInstalled {
      // 1 ETH = 10^18 wei = 0xde0b6b3a7640000
      MockURLProtocol.stub(method: "eth_getBalance", result: "0x0de0b6b3a7640000")

      let reader = makeReader()
      let balance = try await reader.getNativeBalance(chainId: 1, walletAddress: walletAddress)
      #expect(balance == 1.0)
      #expect(MockURLProtocol.recordedMethods == ["eth_getBalance"])
    }
  }

  @Test("getERC20Balance reads eth_call with custom decimals")
  func testGetERC20Balance() async throws {
    try await MockURLProtocol.withInstalled {
      // 100 USDC = 100 * 10^6 = 100_000_000 = 0x5f5e100
      MockURLProtocol.stub(method: "eth_call", result: "0x0000000000000000000000000000000000000000000000000000000005f5e100")

      let reader = makeReader()
      let balance = try await reader.getERC20Balance(
        chainId: 1,
        tokenAddress: usdcAddress,
        walletAddress: walletAddress,
        decimals: 6
      )
      #expect(balance == 100.0)
      #expect(MockURLProtocol.recordedMethods == ["eth_call"])
    }
  }

  @Test("getERC20Balance defaults to 18 decimals when none provided")
  func testGetERC20BalanceDefaultDecimals() async throws {
    try await MockURLProtocol.withInstalled {
      // 1.0 = 10^18 = 0xde0b6b3a7640000
      MockURLProtocol.stub(method: "eth_call", result: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000")

      let reader = makeReader()
      let balance = try await reader.getERC20Balance(
        chainId: 1,
        tokenAddress: daiAddress,
        walletAddress: walletAddress,
        decimals: nil
      )
      #expect(balance == 1.0)
    }
  }

  @Test("getNativeBalance surfaces an error for a malformed eth_getBalance payload instead of a zero balance")
  func testGetNativeBalanceMalformedPayload() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_getBalance", result: "0xZZ")

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getNativeBalance(chainId: 1, walletAddress: walletAddress)
      }
    }
  }

  // MARK: - Allowances

  @Test("getERC20Allowance reads eth_call and returns exact base units")
  func testGetERC20Allowance() async throws {
    try await MockURLProtocol.withInstalled {
      // 250 USDC at 6 decimals = 250_000_000 = 0xee6b280.
      MockURLProtocol.stub(
        method: "eth_call",
        result: "0x000000000000000000000000000000000000000000000000000000000ee6b280"
      )

      let reader = makeReader()
      let allowance = try await reader.getERC20Allowance(
        chainId: 1,
        tokenAddress: usdcAddress,
        owner: walletAddress,
        spender: spenderAddress
      )

      #expect(allowance == BigUInt(250_000_000))
      #expect(MockURLProtocol.recordedMethods == ["eth_call"])
    }
  }

  @Test("an unlimited allowance comes back exact rather than saturating")
  func testGetERC20AllowanceUnlimited() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_call", result: "0x" + String(repeating: "f", count: 64))

      let reader = makeReader()
      let allowance = try await reader.getERC20Allowance(
        chainId: 1,
        tokenAddress: usdcAddress,
        owner: walletAddress,
        spender: spenderAddress
      )

      #expect(allowance == RainTokenAllowance.unlimitedRawAmount)
    }
  }

  /// The block tag is the whole defence against a load-balanced endpoint answering a
  /// post-transaction read from a replica that is still behind. Defaulting it is fine for a
  /// standalone read; silently ignoring a caller's block would put the staleness bug straight back.
  @Test("getERC20Allowance reads at the requested block rather than at latest")
  func testGetERC20AllowanceReadsAtRequestedBlock() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_call", result: "0x" + String(repeating: "0", count: 57) + "ee6b280")

      let reader = makeReader()
      _ = try await reader.getERC20Allowance(
        chainId: 1,
        tokenAddress: usdcAddress,
        owner: walletAddress,
        spender: spenderAddress,
        atBlock: "0x1a2b3c"
      )

      #expect(MockURLProtocol.recordedParams.last?.last as? String == "0x1a2b3c")
    }
  }

  @Test("getERC20Allowance defaults to latest when no block is given")
  func testGetERC20AllowanceDefaultsToLatest() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_call", result: "0x" + String(repeating: "0", count: 57) + "ee6b280")

      let reader = makeReader()
      _ = try await reader.getERC20Allowance(
        chainId: 1,
        tokenAddress: usdcAddress,
        owner: walletAddress,
        spender: spenderAddress
      )

      #expect(MockURLProtocol.recordedParams.last?.last as? String == "latest")
    }
  }

  @Test("getERC20Allowance surfaces a malformed payload instead of reporting no allowance")
  func testGetERC20AllowanceMalformedPayload() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_call", result: "0x")

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getERC20Allowance(
          chainId: 1,
          tokenAddress: usdcAddress,
          owner: walletAddress,
          spender: spenderAddress
        )
      }
    }
  }

  @Test("getERC20Allowance rejects a malformed spender before hitting the network")
  func testGetERC20AllowanceRejectsMalformedSpender() async throws {
    let reader = makeReader()
    await #expect(throws: RainError.self) {
      _ = try await reader.getERC20Allowance(
        chainId: 1,
        tokenAddress: usdcAddress,
        owner: walletAddress,
        spender: "0xnope"
      )
    }
  }

  // MARK: - Transaction receipts

  /// The status field is a JSON-RPC *quantity*, and nodes disagree about minimal encoding. Every
  /// spelling of 1 has to read as success: an approval that mined is the input this drives, and
  /// rejecting a valid receipt would fail a confirmation that in fact succeeded.
  @Test("a successful receipt is recognised however the node encodes the status")
  func testReceiptStatusSuccessEncodings() async throws {
    for encoded in ["0x1", "0X1", "0x01", "0x0000000000000001"] {
      try await MockURLProtocol.withInstalled {
        MockURLProtocol.stub(
          method: "eth_getTransactionReceipt",
          result: ["status": encoded, "blockNumber": "0x10"]
        )

        let reader = makeReader()
        let receipt = try await reader.getTransactionReceipt(
          chainId: 1,
          transactionHash: txHash
        )
        #expect(receipt?.succeeded == true, "status \(encoded)")
      }
    }
  }

  @Test("a reverted receipt is recognised however the node encodes the status")
  func testReceiptStatusRevertedEncodings() async throws {
    for encoded in ["0x0", "0X0", "0x00", "0x0000000000000000"] {
      try await MockURLProtocol.withInstalled {
        MockURLProtocol.stub(
          method: "eth_getTransactionReceipt",
          result: ["status": encoded, "blockNumber": "0x10"]
        )

        let reader = makeReader()
        let receipt = try await reader.getTransactionReceipt(
          chainId: 1,
          transactionHash: txHash
        )
        #expect(receipt?.succeeded == false, "status \(encoded)")
      }
    }
  }

  /// A pending transaction: the node has the hash but no receipt yet. `nil` means keep polling.
  @Test("a null result reads as pending rather than reverted")
  func testReceiptStatusPending() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_getTransactionReceipt", result: NSNull())

      let reader = makeReader()
      let receipt = try await reader.getTransactionReceipt(
        chainId: 1,
        transactionHash: txHash
      )
      #expect(receipt == nil)
    }
  }

  /// The block the transaction landed in is what a confirmation pins its read to, so losing it
  /// here is what forced verification back onto `latest` — and onto whatever head answered.
  @Test("a mined receipt carries the block it landed in")
  func testReceiptCarriesBlockNumber() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(
        method: "eth_getTransactionReceipt",
        result: ["status": "0x1", "blockNumber": "0x10"]
      )

      let reader = makeReader()
      let receipt = try await reader.getTransactionReceipt(chainId: 1, transactionHash: txHash)
      #expect(receipt?.blockNumber == "0x10")
    }
  }

  @Test("a receipt with no blockNumber is malformed rather than confirmable")
  func testReceiptMissingBlockNumber() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_getTransactionReceipt", result: ["status": "0x1"])

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getTransactionReceipt(chainId: 1, transactionHash: txHash)
      }
    }
  }

  /// The value is sent back to a node as a block tag, so a non-quantity cannot be passed through.
  @Test("a non-quantity blockNumber is rejected rather than used as a block tag")
  func testReceiptNonQuantityBlockNumber() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(
        method: "eth_getTransactionReceipt",
        result: ["status": "0x1", "blockNumber": "latest"]
      )

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getTransactionReceipt(chainId: 1, transactionHash: txHash)
      }
    }
  }

  @Test("a status outside 0 and 1 is malformed rather than guessed at")
  func testReceiptStatusOutOfRange() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(
        method: "eth_getTransactionReceipt",
        result: ["status": "0x2", "blockNumber": "0x10"]
      )

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getTransactionReceipt(chainId: 1, transactionHash: txHash)
      }
    }
  }

  @Test("a non-hex status is malformed rather than guessed at")
  func testReceiptStatusNonHex() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(
        method: "eth_getTransactionReceipt",
        result: ["status": "success", "blockNumber": "0x10"]
      )

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getTransactionReceipt(chainId: 1, transactionHash: txHash)
      }
    }
  }

  /// Pre-Byzantium receipts carry no status. Unknown is not success.
  @Test("a receipt with no status field throws instead of reading as mined")
  func testReceiptStatusMissing() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(
        method: "eth_getTransactionReceipt",
        result: ["blockNumber": "0x10"]
      )

      let reader = makeReader()
      await #expect(throws: RainError.internalError(details: "")) {
        _ = try await reader.getTransactionReceipt(chainId: 1, transactionHash: txHash)
      }
    }
  }

  @Test("a malformed transaction hash is rejected before hitting the network")
  func testReceiptStatusRejectsMalformedHash() async throws {
    try await MockURLProtocol.withInstalled {
      let reader = makeReader()
      let malformed = [
        "0xnope",
        "0x" + String(repeating: "a", count: 63),
        "0x" + String(repeating: "a", count: 65),
        String(repeating: "a", count: 64),
      ]

      for hash in malformed {
        await #expect(throws: RainError.invalidConfig(details: "")) {
          _ = try await reader.getTransactionReceipt(chainId: 1, transactionHash: hash)
        }
      }
      #expect(MockURLProtocol.recordedMethods.isEmpty)
    }
  }

  // MARK: - Address validation

  @Test("getNativeBalance throws when the wallet address is syntactically invalid")
  func testGetNativeBalanceRejectsMalformedAddress() async throws {
    let reader = makeReader()
    await #expect(throws: RainError.self) {
      _ = try await reader.getNativeBalance(chainId: 1, walletAddress: "not-an-address")
    }
  }

  @Test("getERC20Balance throws when the token address is syntactically invalid")
  func testGetERC20BalanceRejectsMalformedToken() async throws {
    let reader = makeReader()
    await #expect(throws: RainError.self) {
      _ = try await reader.getERC20Balance(
        chainId: 1,
        tokenAddress: "0xtoo-short",
        walletAddress: walletAddress,
        decimals: 6
      )
    }
  }

  // MARK: - Multicall3 batched balances

  @Test("getBalances on a canonically-deployed chain issues exactly one Multicall3 eth_call (no probe)")
  func testGetBalancesNativeOnly() async throws {
    try await MockURLProtocol.withInstalled {
      let response = encodedAggregate3Response(tuples: [
        (success: true, returnData: paddedUint256(value: "0de0b6b3a7640000"))  // 1 ETH
      ])
      MockURLProtocol.stub(method: "eth_call", result: response)

      let reader = makeReader(chainId: canonicalChainId)
      let balances = try await reader.getBalances(chainId: canonicalChainId, walletAddress: walletAddress, tokens: [])
      #expect(balances.count == 1)
      #expect(balances.first { $0.token == .native }?.decimalAmount == 1.0)
      // Static deployment list — no eth_getCode probe.
      #expect(MockURLProtocol.recordedMethods == ["eth_call"])
      #expect(multicallTarget() == Multicall3.canonicalAddress)
    }
  }

  /// The canonical address has no code on zkSync Era; batching there must go to its own deployment.
  @Test("getBalances on zkSync Era targets the zkSync Multicall3 address, not the canonical one")
  func testGetBalancesZkSyncEraUsesChainSpecificDeployment() async throws {
    try await MockURLProtocol.withInstalled {
      let zkSyncEra = 324
      let response = encodedAggregate3Response(tuples: [
        (success: true, returnData: paddedUint256(value: "0de0b6b3a7640000"))
      ])
      MockURLProtocol.stub(method: "eth_call", result: response)

      let reader = makeReader(chainId: zkSyncEra)
      let balances = try await reader.getBalances(chainId: zkSyncEra, walletAddress: walletAddress, tokens: [])
      #expect(balances.count == 1)
      #expect(MockURLProtocol.recordedMethods == ["eth_call"])
      #expect(multicallTarget() == Multicall3.zkSyncEraAddress)
      #expect(multicallTarget() != Multicall3.canonicalAddress)
    }
  }

  /// The `to` of the one `eth_call` an aggregate3 batch issues.
  private func multicallTarget() -> String? {
    (MockURLProtocol.recordedParams.last?.first as? [String: Any])?["to"] as? String
  }

  @Test("getBalances batches native + tokens into a single Multicall3 call")
  func testGetBalancesBatchHappyPath() async throws {
    try await MockURLProtocol.withInstalled {
      let tokens = [
        TokenInfo(chainId: 1, address: usdcAddress, symbol: "USDC", decimals: 6),
        TokenInfo(chainId: 1, address: daiAddress, symbol: "DAI", decimals: 18)
      ]
      let response = encodedAggregate3Response(tuples: [
        (success: true, returnData: paddedUint256(value: "06f05b59d3b20000")),  // 0.5 * 10^18
        (success: true, returnData: paddedUint256(value: "0ee6b280")),          // 250 * 10^6
        (success: true, returnData: paddedUint256(value: "0de0b6b3a7640000"))   // 1 * 10^18
      ])
      MockURLProtocol.stub(method: "eth_call", result: response)

      let reader = makeReader(chainId: canonicalChainId)
      let balances = try await reader.getBalances(chainId: canonicalChainId, walletAddress: walletAddress, tokens: tokens)
      #expect(balances.count == 3)
      #expect(balances.first { $0.token == .native }?.decimalAmount == 0.5)
      #expect(balances.first { $0.token == .contract(address: usdcAddress) }?.decimalAmount == 250.0)
      #expect(balances.first { $0.token == .contract(address: daiAddress) }?.decimalAmount == 1.0)
      #expect(MockURLProtocol.recordedMethods == ["eth_call"])
    }
  }

  @Test("getBalances omits tokens whose Multicall3 entry reports success=false")
  func testGetBalancesPerEntryFailureOmitsToken() async throws {
    try await MockURLProtocol.withInstalled {
      let tokens = [
        TokenInfo(chainId: 1, address: usdcAddress, symbol: "USDC", decimals: 6),
        TokenInfo(chainId: 1, address: daiAddress, symbol: "DAI", decimals: 18)
      ]
      let response = encodedAggregate3Response(tuples: [
        (success: true, returnData: paddedUint256(value: "0de0b6b3a7640000")),
        (success: false, returnData: ""),
        (success: true, returnData: paddedUint256(value: "0de0b6b3a7640000"))
      ])
      MockURLProtocol.stub(method: "eth_call", result: response)

      let reader = makeReader(chainId: canonicalChainId)
      let balances = try await reader.getBalances(chainId: canonicalChainId, walletAddress: walletAddress, tokens: tokens)
      // Native + DAI present, USDC (the failed entry) omitted.
      #expect(balances.contains { $0.token == .native })
      #expect(balances.contains { $0.token == .contract(address: daiAddress) })
      #expect(!balances.contains { $0.token == .contract(address: usdcAddress) })
    }
  }

  @Test("getBalances throws invalidConfig when chain has no RPC URL configured")
  func testGetBalancesUnknownChain() async throws {
    let reader = makeReader(chainId: 1)
    await #expect(throws: RainError.self) {
      _ = try await reader.getBalances(chainId: 99999, walletAddress: walletAddress, tokens: [])
    }
  }

  @Test("resolveRpcUrl reports the correct chainId when the configured URL is unparseable")
  func testInvalidRpcUrlReportsCorrectChain() async throws {
    let badConfig = NetworkConfig.testConfig(chainId: 1, rpcUrl: "")
    let reader = EVMChainReader(networkConfigResolver: { id in id == 1 ? badConfig : nil })
    do {
      _ = try await reader.getNativeBalance(chainId: 1, walletAddress: walletAddress)
      Issue.record("Expected invalidConfig to throw")
    } catch let error as RainError {
      if case .invalidConfig(let details) = error {
        #expect(details.contains("chainId=1"))
      } else {
        Issue.record("Expected .invalidConfig, got \(error)")
      }
    }
  }

  // MARK: - Parallel fallback path (non-canonical chain)

  @Test("getBalances on a non-canonical chain takes the parallel fallback path")
  func testGetBalancesFallback() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_getBalance", result: "0x0de0b6b3a7640000") // 1 ETH
      MockURLProtocol.stub(method: "eth_call", result: "0x0000000000000000000000000000000000000000000000000000000005f5e100") // 100 (6dp)

      let tokens = [
        TokenInfo(chainId: nonCanonicalChainId, address: usdcAddress, symbol: "USDC", decimals: 6),
        TokenInfo(chainId: nonCanonicalChainId, address: daiAddress, symbol: "DAI", decimals: 6)
      ]
      let reader = makeReader(chainId: nonCanonicalChainId)
      let balances = try await reader.getBalances(chainId: nonCanonicalChainId, walletAddress: walletAddress, tokens: tokens)

      #expect(balances.first { $0.token == .native }?.decimalAmount == 1.0)
      #expect(balances.first { $0.token == .contract(address: usdcAddress) }?.decimalAmount == 100.0)
      #expect(balances.first { $0.token == .contract(address: daiAddress) }?.decimalAmount == 100.0)
      // No probe; 1 eth_getBalance + 2 eth_call (one per token).
      #expect(MockURLProtocol.recordedMethods.filter { $0 == "eth_getCode" }.count == 0)
      #expect(MockURLProtocol.recordedMethods.filter { $0 == "eth_getBalance" }.count == 1)
      #expect(MockURLProtocol.recordedMethods.filter { $0 == "eth_call" }.count == 2)
    }
  }

  // MARK: - Aggregate3 response fixture helpers

  /// Returns a uint256 hex with `0x` prefix, given the trailing significant nibbles.
  private func paddedUint256(value: String) -> String {
    let padded = String(repeating: "0", count: max(0, 64 - value.count)) + value
    return "0x" + padded
  }

  /// Builds a canonical ABI-encoded `aggregate3` response containing the supplied tuples.
  private func encodedAggregate3Response(tuples: [(success: Bool, returnData: String)]) -> String {
    // Outer offset = 0x20, then [length, offsets..., bodies...]
    var out = "0x"
    out += hex32(32)
    out += hex32(tuples.count)
    let headerSize = 32 * tuples.count
    // Compute each tuple's body size: 96 (head) + padded(returnData)
    var offsets: [Int] = []
    var bodies: [String] = []
    var running = headerSize
    for tuple in tuples {
      offsets.append(running)
      let dataHex = stripPrefix(tuple.returnData)
      let dataBytes = dataHex.count / 2
      let paddedBytes = ((dataBytes + 31) / 32) * 32
      let bodySize = 96 + paddedBytes
      running += bodySize
      // Body: success(32) + dataOffset(32 = 0x40) + dataLength(32) + paddedData
      var body = hex32(tuple.success ? 1 : 0)
      body += hex32(64)
      body += hex32(dataBytes)
      let padChars = paddedBytes * 2 - dataHex.count
      body += dataHex + String(repeating: "0", count: padChars)
      bodies.append(body)
    }
    for offset in offsets {
      out += hex32(offset)
    }
    for body in bodies {
      out += body
    }
    return out
  }

  private func hex32(_ value: Int) -> String {
    let h = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 64 - h.count)) + h
  }

  private func stripPrefix(_ s: String) -> String {
    (s.hasPrefix("0x") || s.hasPrefix("0X")) ? String(s.dropFirst(2)) : s
  }
}
