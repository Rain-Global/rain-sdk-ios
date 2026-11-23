import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

@Suite("SolanaChainReader", .serialized)
struct SolanaChainReaderTests {
  private static let host = "solana.test"
  private static let rpcUrl = "https://solana.test/rpc"
  private let address = Base58.encode((0..<32).map { UInt8($0) })

  private func makeReader() -> SolanaChainReader {
    SolanaChainReader(networkConfigs: [.testConfig(chainId: SolanaChains.mainnet, rpcUrl: Self.rpcUrl)])
  }

  @Test("native balance reads lamports and converts to SOL")
  func nativeBalance() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_500_000_000])
      let reader = makeReader()

      let sol = try await reader.getNativeBalance(chainId: SolanaChains.mainnet, walletAddress: address)
      #expect(sol == 1.5)

      let balance = try await reader.getBalance(
        chainId: SolanaChains.mainnet, walletAddress: address, token: .native, tokenInfo: nil)
      #expect(balance.token == .native)
      #expect(balance.symbol == "SOL")
      #expect(balance.decimals == 9)
      #expect(balance.rawAmount == BigUInt(1_500_000_000))
      #expect(balance.decimalAmount == Decimal(string: "1.5"))
    }
  }

  @Test("getBalances returns native only")
  func balancesNativeOnly() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000])
      let reader = makeReader()
      let balances = try await reader.getBalances(chainId: SolanaChains.mainnet, walletAddress: address, tokens: [])
      #expect(balances.count == 1)
      #expect(balances.first?.token == .native)
    }
  }

  @Test("SPL balance reads the wallet's associated token account for the mint")
  func splBalance() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      // The mint is resolved first (its program seeds the account derivation), then the account.
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 6),
        Self.tokenAccountInfo(amount: "2000000", decimals: 6)
      ])
      let reader = makeReader()

      let balance = try await reader.getBalance(
        chainId: SolanaChains.mainnet, walletAddress: address,
        token: .contract(address: Self.mint), tokenInfo: nil)
      #expect(balance.token == .contract(address: Self.mint))
      #expect(balance.rawAmount == BigUInt(2_000_000))
      #expect(balance.decimals == 6)
      #expect(balance.decimalAmount == 2)
    }
  }

  @Test("an owner with no token account holds zero, with decimals read from the mint")
  func splBalanceWithoutAccount() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 9),
        ["value": NSNull()] // the wallet has never held this mint
      ])
      let reader = makeReader()

      let balance = try await reader.getBalance(
        chainId: SolanaChains.mainnet, walletAddress: address,
        token: .contract(address: Self.mint), tokenInfo: nil)
      #expect(balance.rawAmount == 0)
      #expect(balance.decimals == 9)
    }
  }

  @Test("getERC20Balance scales by the mint's decimals, ignoring a caller override")
  func splBalanceIgnoresDecimalsOverride() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 6),
        Self.tokenAccountInfo(amount: "2000000", decimals: 6)
      ])
      let reader = makeReader()

      let value = try await reader.getERC20Balance(
        chainId: SolanaChains.mainnet, tokenAddress: Self.mint,
        walletAddress: address, decimals: 2)
      #expect(value == 2)
    }
  }

  @Test("a balance for a mint that does not exist surfaces tokenNotFound")
  func splBalanceUnknownMint() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", result: ["value": NSNull()])
      let reader = makeReader()

      await #expect(throws: RainError.tokenNotFound(token: Self.mint, chainId: SolanaChains.mainnet)) {
        _ = try await reader.getBalance(
          chainId: SolanaChains.mainnet, walletAddress: address,
          token: .contract(address: Self.mint), tokenInfo: nil)
      }
    }
  }

  @Test("getBalances discovers the wallet's mints across both token programs")
  func balancesDiscoverTokens() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000])
      // One query per token program, answered by which program was asked for (they run
      // concurrently, so arrival order is not stable).
      MockURLProtocol.stub(method: "getTokenAccountsByOwner") { params in
        Self.isToken2022(params)
          ? ["value": [
              Self.tokenAccountRow(pubkey: "acct-3", amount: "100", decimals: 2, mint: Self.otherMint)
            ]]
          : ["value": [
              Self.tokenAccountRow(pubkey: "acct-1", amount: "42", decimals: 0),
              // A second account for the same mint — the balance is the sum.
              Self.tokenAccountRow(pubkey: "acct-2", amount: "8", decimals: 0)
            ]]
      }
      let reader = makeReader()

      let balances = try await reader.getBalances(
        chainId: SolanaChains.mainnet,
        walletAddress: address,
        // Registered metadata is only used to label a discovered mint.
        tokens: [TokenInfo(chainId: SolanaChains.mainnet, address: Self.mint, symbol: "TEST", decimals: 0, name: nil)]
      )
      #expect(balances.count == 3)
      #expect(balances[0].token == .native)
      #expect(balances[1].token == .contract(address: Self.mint))
      #expect(balances[1].rawAmount == BigUInt(50))
      #expect(balances[1].symbol == "TEST")
      // Discovered without being registered: decimals come from the account, symbol is unknown.
      #expect(balances[2].token == .contract(address: Self.otherMint))
      #expect(balances[2].rawAmount == BigUInt(100))
      #expect(balances[2].decimals == 2)
      #expect(balances[2].symbol == nil)
    }
  }

  @Test("getBalances still returns native SOL when token discovery fails")
  func balancesSurviveDiscoveryFailure() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000])
      MockURLProtocol.stubError(
        method: "getTokenAccountsByOwner",
        error: URLError(.timedOut)
      )
      let reader = makeReader()

      let balances = try await reader.getBalances(
        chainId: SolanaChains.mainnet, walletAddress: address, tokens: [])
      #expect(balances.count == 1)
      #expect(balances[0].token == .native)
    }
  }

  @Test("an account that is not an SPL mint is rejected")
  func nonMintRejected() async throws {
    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(
        method: "getAccountInfo",
        result: ["value": ["owner": SolanaPrograms.system, "data": ["parsed": ["type": "account"]]]]
      )
      let reader = makeReader()
      await #expect(throws: RainError.tokenNotFound(token: Self.mint, chainId: SolanaChains.mainnet)) {
        _ = try await reader.getDecimals(chainId: SolanaChains.mainnet, tokenAddress: Self.mint)
      }
    }
  }

  @Test("token metadata reads report unknown rather than throwing")
  func metadataReadsReportUnknown() async throws {
    let reader = makeReader()
    // Symbols and names live in Metaplex metadata, which the SDK does not read. Throwing here
    // would abort enrichment for a token whose balance is perfectly readable.
    #expect(try await reader.getSymbol(chainId: SolanaChains.mainnet, tokenAddress: Self.mint) == nil)
    #expect(try await reader.getName(chainId: SolanaChains.mainnet, tokenAddress: Self.mint) == nil)
  }

  // MARK: - Fixtures

  private static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

  /// Whether a `getTokenAccountsByOwner` call asked for the Token-2022 program.
  private static func isToken2022(_ params: [Any]) -> Bool {
    (params.dropFirst().first as? [String: Any])?["programId"] as? String == SolanaPrograms.token2022
  }
  private static let otherMint = "So11111111111111111111111111111111111111112"

  private static func tokenAccountRow(
    pubkey: String,
    amount: String,
    decimals: Int,
    mint: String = SolanaChainReaderTests.mint
  ) -> [String: Any] {
    [
      "pubkey": pubkey,
      "account": ["data": ["parsed": ["info": [
        "mint": mint,
        "tokenAmount": ["amount": amount, "decimals": decimals]
      ]]]]
    ]
  }

  /// A `getAccountInfo` payload for a token account holding `amount`.
  private static func tokenAccountInfo(amount: String, decimals: Int) -> [String: Any] {
    ["value": [
      "owner": SolanaPrograms.splToken,
      "data": ["parsed": [
        "type": "account",
        "info": [
          "mint": mint,
          "owner": "owner-wallet",
          "tokenAmount": ["amount": amount, "decimals": decimals]
        ]
      ]]
    ]]
  }

  private static func mintAccountInfo(decimals: Int) -> [String: Any] {
    ["value": [
      "owner": SolanaPrograms.splToken,
      "data": ["parsed": ["type": "mint", "info": ["decimals": decimals]]]
    ]]
  }

  @Test("invalid Solana address throws")
  func invalidAddressThrows() async {
    let reader = makeReader()
    await #expect(throws: RainError.self) {
      _ = try await reader.getNativeBalance(chainId: SolanaChains.mainnet, walletAddress: "not-base58-0OIl")
    }
  }
}
