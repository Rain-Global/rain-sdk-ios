import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

@Suite("Collateral Admin Check Tests")
struct CollateralAdminCheckTests {
  private let proxy = TestFixtures.defaultWithdrawAddresses.proxyAddress
  private let word = { (last: String) in "0x" + String(repeating: "0", count: 64 - last.count) + last }

  // MARK: - Decoding the isAdmin answer

  @Test("a one or zero word is an answer; extra whole words after it are ignored")
  func wordsDecode() throws {
    #expect(try TransactionBuilderService.adminCheck(fromCallResult: word("1"), proxy: proxy) == .admin)
    #expect(try TransactionBuilderService.adminCheck(fromCallResult: word("0"), proxy: proxy) == .notAdmin)
    #expect(try TransactionBuilderService.adminCheck(fromCallResult: word("1") + String(repeating: "f", count: 64), proxy: proxy) == .admin)
  }

  @Test("no data or a word other than 0 or 1 is not a collateral contract")
  func notCollateralAnswers() throws {
    #expect(try TransactionBuilderService.adminCheck(fromCallResult: "0x", proxy: proxy) == .notCollateral)
    #expect(try TransactionBuilderService.adminCheck(fromCallResult: word("2"), proxy: proxy) == .notCollateral)
  }

  @Test("an answer that is not whole words of hex does not decode")
  func undecodableAnswers() {
    let bad = [
      nil,
      word("1") + "00",
      "0x+" + String(repeating: "0", count: 62) + "1",
      word("1").replacingOccurrences(of: "1", with: "g"),
    ]
    for result in bad {
      #expect(throws: RainError.internalError(details: ""), "\(result ?? "nil") must be RAIN_502, not read as admin") {
        _ = try TransactionBuilderService.adminCheck(fromCallResult: result, proxy: proxy)
      }
    }
  }

  // MARK: - The revert rule

  @Test("code 3 alone, or a revert named in the message or in string data, is a revert")
  func revertRule() {
    #expect(JsonRpcClient.isRevert(code: 3, message: "VM execution error.", data: nil))
    #expect(JsonRpcClient.isRevert(code: -32015, message: "VM execution error.", data: "Reverted 0x"))
    #expect(JsonRpcClient.isRevert(code: -32000, message: "execution reverted", data: nil))
    #expect(!JsonRpcClient.isRevert(code: -32000, message: "header not found", data: nil))
  }

  private let rpcUrl = "https://mainnet.infura.io/"

  @Test("an EVM call answered with code 3, or a revert named only in string data, is RAIN_403")
  func evmRevertThroughClient() async throws {
    let answers: [[String: Any]] = [
      ["code": 3, "message": "VM execution error."],
      ["code": -32015, "message": "VM execution error.", "data": "Reverted 0x"],
    ]
    try await MockURLProtocol.withInstalled {
      for answer in answers {
        MockURLProtocol.stubRPCError(method: "eth_call", error: answer)
        let error = await #expect(throws: RainError.self) {
          _ = try await JsonRpcClient().call(rpcUrl: rpcUrl, method: "eth_call", params: [])
        }
        #expect(error?.code == "RAIN_403", "a revert marked by code 3 or in data is still a revert (\(answer))")
      }
    }
  }

  @Test("a Solana node's error is not an EVM revert, whatever its data says")
  func solanaErrorIsNotARevert() async throws {
    let answers: [[String: Any]] = [
      ["code": -32002, "message": "Transaction simulation failed", "data": "Program log: reverted"],
      ["code": -32002, "message": "Transaction simulation failed", "data": ["err": "AccountNotFound", "logs": ["Program log: reverted"]]],
    ]
    try await MockURLProtocol.withInstalled {
      for answer in answers {
        MockURLProtocol.stubRPCError(method: "simulateTransaction", error: answer)
        let error = await #expect(throws: RainError.self) {
          _ = try await JsonRpcClient().call(rpcUrl: rpcUrl, method: "simulateTransaction", params: [])
        }
        #expect(error?.code != "RAIN_403", "Solana methods keep the message-only check, so string data must not flip them (\(answer))")
      }
    }
  }

  // MARK: - Reading the admin nonce

  @Test("an adminNonce read answers RAIN_102 for a bad address, RAIN_502 for a node error or bad value, RAIN_301 for transport")
  func adminNonceErrorContract() async throws {
    let builder = TransactionBuilderService(networkConfigs: TestFixtures.configs())
    let badChecksum = "0xABCDEFabcdefabcdefabcdefabcdefabcdefabcd"
    await #expect(throws: RainError.invalidConfig(details: ""), "a proxy failing its EIP-55 checksum is a config error") {
      _ = try await builder.getLatestNonce(proxyAddress: badChecksum, chainId: 1)
    }

    let stubs: [(String, () -> Void)] = [
      ("RAIN_502", { MockURLProtocol.stub(method: "eth_call", result: self.word("7") + "00") }),
      ("RAIN_502", { MockURLProtocol.stub(method: "eth_call", result: self.word("7") + String(repeating: "z", count: 64)) }),
      ("RAIN_502", { MockURLProtocol.stubRPCError(method: "eth_call", error: ["code": 3, "message": "execution reverted"]) }),
      ("RAIN_502", { MockURLProtocol.stubRPCError(method: "eth_call", error: ["code": -32000, "message": "header not found"]) }),
      ("RAIN_301", { MockURLProtocol.stubError(method: "eth_call", error: URLError(.notConnectedToInternet)) }),
      ("RAIN_301", { MockURLProtocol.stubRawBody(method: "eth_call", body: "<html>502 Bad Gateway</html>") }),
    ]
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stub(method: "eth_call", result: word("7") + String(repeating: "f", count: 64))
      let nonce = try await builder.getLatestNonce(proxyAddress: proxy, chainId: 1)
      #expect(nonce == 7, "only the first word of a longer answer is the nonce")

      for (code, stub) in stubs {
        stub()
        let error = await #expect(throws: RainError.self) {
          _ = try await builder.getLatestNonce(proxyAddress: proxy, chainId: 1)
        }
        #expect(error?.code == code, "the same codes Android's getLatestNonce answers (\(String(describing: error)))")
      }
      let check = try await builder.isCollateralAdmin(proxyAddress: proxy, walletAddress: proxy, chainId: 1)
      #expect(check == .failed(.networkError(underlying: URLError(.badServerResponse))), "a reply that is not JSON is a network failure")
    }
  }

  @Test("a withdrawal against a contract with no adminNonce is RAIN_502, not a network revert")
  func withdrawalOnContractWithoutAdminNonce() async throws {
    let configs = TestFixtures.configs()
    let manager = RainSdkManager(
      walletProvider: StubWalletProvider(),
      networkConfigs: configs,
      transactionBuilder: TransactionBuilderService(networkConfigs: configs),
      tokenStore: TokenMetadataStore(chainReader: EVMChainReader(networkConfigs: configs)),
      providerId: ProviderId("stub"),
      capabilities: []
    )
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.stubRPCError(method: "eth_call", error: ["code": 3, "message": "execution reverted"])
      let error = await #expect(throws: RainError.self) {
        _ = try await manager.prepareWithdrawal(
          chainId: 1,
          addresses: TestFixtures.defaultWithdrawAddresses,
          amount: 1,
          decimals: 6,
          adminSignature: TestFixtures.adminSignature(),
          nonce: nil
        )
      }
      #expect(error?.code == "RAIN_502", "a wrong proxyAddress must not read as the network rejecting the withdrawal")
    }
  }

  // MARK: - Withdrawals stay lenient

  @Test("a withdrawal is refused only when the collateral answers that the wallet is not an admin")
  func withdrawalBlocksOnlyOnNotAdmin() async throws {
    let rows: [(CollateralAdminCheck, String?)] = [
      (.admin, nil),
      (.notAdmin, "RAIN_407"),
      (.failed(.networkError(underlying: URLError(.notConnectedToInternet))), nil),
      (.notCollateral, nil),
    ]
    for (check, code) in rows {
      let builder = MockTransactionBuilderService(networkConfigs: TestFixtures.configs())
      builder.mockIsCollateralAdmin = check
      let (manager, _) = try await TestManagers.stubProviderManager(stub: StubWalletProvider(), builder: builder)

      var thrown: RainError?
      do {
        _ = try await manager.prepareWithdrawal(
          chainId: 1,
          addresses: TestFixtures.defaultWithdrawAddresses,
          amount: 1,
          decimals: 6,
          adminSignature: TestFixtures.adminSignature(),
          nonce: 1
        )
      } catch let error as RainError {
        thrown = error
      }
      #expect(thrown?.code == code, "\(check): a check that cannot answer never blocks a withdrawal")
    }
  }
}
