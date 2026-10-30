import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

@Suite("SolanaRpcClient", .serialized)
struct SolanaRpcClientTests {
  private static let host = "solana.test"
  private static let rpcUrl = "https://solana.test/rpc"
  private let address = Base58.encode((0..<32).map { UInt8($0) })

  private func makeClient() -> SolanaRpcClient {
    SolanaRpcClient(networkConfigs: [.testConfig(chainId: SolanaChains.mainnet, rpcUrl: Self.rpcUrl)])
  }

  @Test("getBalanceLamports parses result.value")
  func balanceLamports() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 2_000_000_000])
      let client = makeClient()
      let lamports = try await client.getBalanceLamports(chainId: SolanaChains.mainnet, address: address)
      #expect(lamports == BigUInt(2_000_000_000))
    }
  }

  @Test("getMinimumBalanceForRentExemption asks for the account size and parses a bare result")
  func minimumBalanceForRentExemption() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getMinimumBalanceForRentExemption", result: 1_488_440)
      let client = makeClient()
      let rent = try await client.getMinimumBalanceForRentExemption(chainId: SolanaChains.mainnet, dataLength: 165)
      #expect(rent == BigUInt(1_488_440))
      #expect(MockURLProtocol.recordedParams.last?.first as? Int == 165)
    }
  }

  @Test("getLatestBlockhash parses result.value.blockhash")
  func latestBlockhash() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": "ABC123"]])
      let client = makeClient()
      let blockhash = try await client.getLatestBlockhash(chainId: SolanaChains.mainnet)
      #expect(blockhash == "ABC123")
    }
  }

  @Test("getLatestSignature returns first signature or nil")
  func latestSignature() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getSignaturesForAddress", result: [["signature": "sig-1"]])
      let client = makeClient()
      let signature = try await client.getLatestSignature(chainId: SolanaChains.mainnet, address: address)
      #expect(signature == "sig-1")
    }
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getSignaturesForAddress", result: [])
      let client = makeClient()
      let signature = try await client.getLatestSignature(chainId: SolanaChains.mainnet, address: address)
      #expect(signature == nil)
    }
  }

  @Test("unconfigured chain throws invalidConfig")
  func unconfiguredChain() async {
    let client = SolanaRpcClient(networkConfigs: [])
    await #expect(throws: RainError.self) {
      _ = try await client.getBalanceLamports(chainId: SolanaChains.mainnet, address: address)
    }
  }
}
