import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

/// The public Solana surface out-of-core adapters (e.g. RainPrivy) build on.
@Suite("RainSolanaChainReader", .serialized)
struct RainSolanaChainReaderTests {
  private static let host = "solana-public.test"
  private static let rpcUrl = "https://solana-public.test/rpc"
  private let address = Base58.encode((0..<32).map { UInt8($0) })
  private let blockhash = Base58.encode((0..<32).map { UInt8($0 + 65) })

  private func makeReader() -> RainSolanaChainReader {
    RainSolanaChainReader(
      networkConfigs: [.testConfig(chainId: SolanaChains.devnet, rpcUrl: Self.rpcUrl)])
  }

  @Test("native balance reads lamports with SOL metadata")
  func nativeBalance() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_500_000_000])

      let balance = try await makeReader().getBalance(
        chainId: SolanaChains.devnet, walletAddress: address)
      #expect(balance.rawAmount.description == "1500000000")
      #expect(balance.decimals == 9)
      #expect(balance.symbol == "SOL")
    }
  }

  @Test("latestBlockhash returns the node's blockhash")
  func latestBlockhash() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])

      let latest = try await makeReader().latestBlockhash(chainId: SolanaChains.devnet)
      #expect(latest == blockhash)
    }
  }

  @Test("an unconfigured cluster surfaces invalidConfig")
  func unconfiguredCluster() async {
    await #expect(throws: RainError.invalidConfig(
      details: "No RPC endpoint configured for chainId=\(SolanaChains.mainnet)"
    )) {
      _ = try await makeReader().latestBlockhash(chainId: SolanaChains.mainnet)
    }
  }
}

/// Pins the composer to the builder's bytes and the SOL → lamports scale. Composition (not just
/// serialization) is what both wallet adapters call, so its output is what has to be stable.
@Suite("SolanaTransferComposer native", .serialized)
struct SolanaTransferComposerNativeTests {
  private static let host = "solana.test"
  private static let rpcUrl = "https://solana.test/rpc"
  private let from = Base58.encode((0..<32).map { UInt8($0 + 1) })
  private let to = Base58.encode((0..<32).map { UInt8($0 + 33) })
  private let blockhash = Base58.encode((0..<32).map { UInt8($0 + 65) })

  private func makeSupport() -> RainSolanaSupport {
    RainSolanaSupport(networkConfigs: [.testConfig(chainId: SolanaChains.devnet, rpcUrl: Self.rpcUrl)])
  }

  @Test("a composed native transfer matches the builder's serialization")
  func matchesBuilder() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])

      let unsigned = try await makeSupport().composeNativeTransfer(
        chainId: SolanaChains.devnet, from: from, to: to, amount: Decimal(string: "1.5")!)
      let expected = try SolanaTransactionBuilder.buildTransferBytes(
        from: from, to: to, lamports: 1_500_000_000, recentBlockhash: blockhash)

      #expect(unsigned.transaction == Data(expected))
      #expect(unsigned.recentBlockhash == blockhash)
      #expect(!unsigned.createsRecipientAccount)
    }
  }

  @Test("sub-lamport precision is rejected rather than truncated, as are bad inputs")
  func amountEdgeCases() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])
      let support = makeSupport()

      // 0.4 lamports: the amount cannot be represented, so it fails instead of sending zero.
      await #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
        _ = try await support.composeNativeTransfer(
          chainId: SolanaChains.devnet, from: from, to: to,
          amount: Decimal(string: "0.0000000004")!)
      }
      await #expect(throws: RainError.self) {
        _ = try await support.composeNativeTransfer(
          chainId: SolanaChains.devnet, from: from, to: to, amount: -1)
      }
      await #expect(throws: RainError.self) {
        _ = try await support.composeNativeTransfer(
          chainId: SolanaChains.devnet, from: from, to: "not-base58", amount: 1)
      }
    }
  }
}
