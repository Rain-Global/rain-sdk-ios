import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

@Suite("TokenMetadataStore Tests")
struct TokenMetadataStoreTests {
  /// An address not present in `TokenRegistry`, used to force the enrichment path.
  static let unknownToken = "0x00000000000000000000000000000000000000ff"

  @Test("known registry token resolves without any enrichment RPC")
  func testKnownTokenResolvesWithoutEnrichment() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    let info = await store.tokenInfo(chainId: 1, address: TestFixtures.usdcAddress)

    #expect(info.symbol == "USDC")
    #expect(info.decimals == 6)
    #expect(reader.decimalsCalls.isEmpty)
    #expect(reader.symbolCalls.isEmpty)
  }

  @Test("unknown token enriches exactly once, then serves from cache")
  func testUnknownTokenEnrichesOnceThenCaches() async throws {
    let reader = MockChainReader()
    reader.stubbedDecimals = 8
    reader.stubbedSymbol = "WBTC"
    reader.stubbedName = "Wrapped BTC"
    let store = TokenMetadataStore(chainReader: reader)

    let first = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(first.decimals == 8)
    #expect(first.symbol == "WBTC")
    #expect(first.name == "Wrapped BTC")
    #expect(reader.decimalsCalls.count == 1)
    #expect(reader.symbolCalls.count == 1)
    #expect(reader.nameCalls.count == 1)

    // Second lookup must hit the cache — no extra RPC.
    let second = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(second == first)
    #expect(reader.decimalsCalls.count == 1)
    #expect(reader.symbolCalls.count == 1)
    #expect(reader.nameCalls.count == 1)
  }

  @Test("resolvedTokenInfo is strict: nil when decimals fail, the chain answer otherwise, then cached")
  func testResolvedTokenInfoIsStrict() async throws {
    let reader = MockChainReader()
    reader.stubbedDecimals = 6
    reader.stubbedSymbol = "EURC"
    reader.stubbedMetadataError = URLError(.cannotConnectToHost)
    let store = TokenMetadataStore(chainReader: reader)

    // No guessed 18: the caller must not scale a money amount on a failed read.
    #expect(try await store.resolvedTokenInfo(chainId: 1, address: Self.unknownToken) == nil)

    reader.stubbedMetadataError = nil
    let resolved = try await store.resolvedTokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(resolved?.decimals == 6)
    #expect(resolved?.symbol == "EURC")
    #expect(reader.decimalsCalls.count == 2)

    _ = try await store.resolvedTokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(reader.decimalsCalls.count == 2) // cached

    // Registry and host-registered tokens answer without RPC.
    let usdc = try await store.resolvedTokenInfo(chainId: 1, address: TestFixtures.usdcAddress)
    #expect(usdc?.decimals == 6)
    #expect(reader.decimalsCalls.count == 2)
  }

  @Test("resolvedTokenInfo on a Solana chain is registry-only: no EVM read, nil when unknown")
  func testResolvedTokenInfoSolanaIsRegistryOnly() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    #expect(try await store.resolvedTokenInfo(chainId: RainChain.solanaDevnet, address: mint) == nil)
    #expect(reader.decimalsCalls.isEmpty)

    try await store.register([TokenInfo(chainId: RainChain.solanaDevnet, address: mint, symbol: "USDC", decimals: 6, name: "USD Coin")])
    let registered = try await store.resolvedTokenInfo(chainId: RainChain.solanaDevnet, address: mint)
    #expect(registered?.symbol == "USDC")
    #expect(reader.decimalsCalls.isEmpty)
  }

  @Test("a fallback decimals is not cached so a later lookup re-reads the chain")
  func testFallbackDecimalsIsNotCached() async throws {
    // A transient RPC failure must not pin the 18-decimals guess for the process lifetime:
    // caching it would misreport a 6-decimal token's balance by a factor of 10^12.
    let reader = MockChainReader()
    reader.stubbedDecimals = 6
    reader.stubbedSymbol = "EURC"
    reader.stubbedMetadataError = URLError(.cannotConnectToHost)
    let store = TokenMetadataStore(chainReader: reader)

    let failed = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(failed.decimals == 18)

    reader.stubbedMetadataError = nil
    let retried = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(retried.decimals == 6)
    #expect(retried.symbol == "EURC")
    #expect(reader.decimalsCalls.count == 2)

    // The successful read is cached — a third lookup issues no further RPC.
    _ = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(reader.decimalsCalls.count == 2)
  }

  @Test("register makes a previously-unknown token resolve without enrichment")
  func testRegisterAvoidsEnrichment() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    try await store.register([
      TokenInfo(chainId: 1, address: Self.unknownToken, symbol: "FOO", decimals: 12, name: "Foo Token")
    ])

    let info = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(info.symbol == "FOO")
    #expect(info.decimals == 12)
    #expect(info.name == "Foo Token")
    #expect(reader.decimalsCalls.isEmpty)
    #expect(reader.symbolCalls.isEmpty)
  }

  /// A wrong `decimals` on a known token would rescale its balances and approvals by orders of
  /// magnitude, so the registry stays authoritative for the addresses it ships.
  @Test("a registration cannot override a built-in token's metadata")
  func testRegisterCannotOverrideRegistryToken() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    try await store.register([
      TokenInfo(chainId: 1, address: TestFixtures.usdcAddress, symbol: "USDX", decimals: 18, name: "Not USDC")
    ])

    let info = await store.tokenInfo(chainId: 1, address: TestFixtures.usdcAddress)
    #expect(info.symbol == "USDC")
    #expect(info.decimals == 6)
    #expect(try await store.decimals(chainId: 1, address: TestFixtures.usdcAddress) == 6)
    let entries = await store.registeredTokens(for: 1)
    #expect(entries.filter { $0.address.lowercased() == TestFixtures.usdcAddress.lowercased() }.count == 1)
    #expect(reader.decimalsCalls.isEmpty)
  }

  @Test("a seed token cannot override a built-in token's metadata either")
  func testSeedCannotOverrideRegistryToken() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(
      chainReader: reader,
      seedTokens: [TokenInfo(chainId: 1, address: TestFixtures.usdcAddress.lowercased(), symbol: "USDC", decimals: 18, name: nil)]
    )

    #expect(try await store.decimals(chainId: 1, address: TestFixtures.usdcAddress) == 6)
    #expect(reader.decimalsCalls.isEmpty)
  }

  @Test("a host-registered token can still be re-registered")
  func testHostTokenCanBeReplaced() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    try await store.register([
      TokenInfo(chainId: 1, address: Self.unknownToken, symbol: "FOO", decimals: 12, name: nil)
    ])
    try await store.register([
      TokenInfo(chainId: 1, address: "0x" + Self.unknownToken.dropFirst(2).uppercased(), symbol: "FOO", decimals: 8, name: "Foo")
    ])

    let info = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(info.decimals == 8)
    #expect(info.name == "Foo")
    let entries = await store.registeredTokens(for: 1)
    #expect(entries.filter { $0.address.lowercased() == Self.unknownToken }.count == 1)
  }

  @Test("seedTokens resolve without enrichment")
  func testSeedTokensResolveWithoutEnrichment() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(
      chainReader: reader,
      seedTokens: [TokenInfo(chainId: 1, address: Self.unknownToken, symbol: "BAR", decimals: 4, name: nil)]
    )

    let info = await store.tokenInfo(chainId: 1, address: Self.unknownToken)
    #expect(info.symbol == "BAR")
    #expect(info.decimals == 4)
    #expect(reader.decimalsCalls.isEmpty)
    #expect(reader.symbolCalls.isEmpty)
  }

  @Test("token lookup is case-insensitive on address")
  func testCaseInsensitiveLookup() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    let lower = await store.tokenInfo(chainId: 1, address: TestFixtures.usdcAddress.lowercased())
    let upper = await store.tokenInfo(chainId: 1, address: TestFixtures.usdcAddress.uppercased())

    #expect(lower.symbol == "USDC")
    #expect(upper.symbol == "USDC")
    #expect(reader.decimalsCalls.isEmpty)
    #expect(reader.symbolCalls.isEmpty)
  }

  @Test("nativeCurrency returns chain-specific metadata")
  func testNativeCurrencyLookup() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    let eth = await store.nativeCurrency(for: 1)
    #expect(eth.symbol == "ETH")

    let avax = await store.nativeCurrency(for: 43114)
    #expect(avax.symbol == "AVAX")
  }

  @Test("nativeCurrencyOrNil returns nil for an unknown chain instead of a default")
  func testNativeCurrencyOrNilOnUnknownChain() async throws {
    let reader = MockChainReader()
    let store = TokenMetadataStore(chainReader: reader)

    #expect(await store.nativeCurrencyOrNil(for: 43114)?.symbol == "AVAX")
    #expect(await store.nativeCurrencyOrNil(for: RainChain.solanaMainnet)?.symbol == "SOL")
    // The ETH-like fallback would label an unlisted chain's gas token wrongly.
    #expect(await store.nativeCurrency(for: 123456).symbol == "ETH")
    #expect(await store.nativeCurrencyOrNil(for: 123456) == nil)
  }

  @Test("register validates the whole list first: a bad entry registers nothing")
  func testRegisterValidatesBeforeStoring() async throws {
    let store = TokenMetadataStore(chainReader: MockChainReader())
    let good = TokenInfo(chainId: 1, address: Self.unknownToken, symbol: "FOO", decimals: 12, name: nil)

    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await store.register([good, TokenInfo(chainId: 1, address: "0xnope", symbol: "X", decimals: 6, name: nil)])
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await store.register([good, TokenInfo(chainId: 1, address: Self.unknownToken, symbol: "X", decimals: 78, name: nil)])
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      // Bare address: the store keys by the string as given, so it would never match its 0x twin.
      try await store.register([TokenInfo(chainId: 1, address: String(Self.unknownToken.dropFirst(2)), symbol: "X", decimals: 6, name: nil)])
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      // Mixed case with a wrong EIP-55 checksum.
      try await store.register([TokenInfo(chainId: 1, address: "0xa0b86991C6218B36c1d19d4a2e9eb0ce3606eb48", symbol: "X", decimals: 6, name: nil)])
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await store.register([TokenInfo(chainId: RainChain.solanaDevnet, address: "not-base58!", symbol: "X", decimals: 6, name: nil)])
    }
    #expect(await store.registeredTokens(for: 1).contains { $0.address == Self.unknownToken } == false)
  }

  @Test("an on-chain decimals outside 0...77 is refused by the strict accessors and never cached")
  func testOutOfRangeChainDecimalsRefused() async throws {
    let reader = MockChainReader()
    reader.stubbedDecimals = 200
    let store = TokenMetadataStore(chainReader: reader)

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await store.resolvedTokenInfo(chainId: 1, address: Self.unknownToken)
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await store.decimals(chainId: 1, address: Self.unknownToken)
    }
    #expect(reader.decimalsCalls.count == 2) // not cached: each lookup re-reads and re-refuses
  }
}
