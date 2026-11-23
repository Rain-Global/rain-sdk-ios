import Testing
import Foundation
@testable import RainCore

/// Rewritten for the modular registry API. The monolith's `RainSDKManager()` +
/// `initializePortal` / `initialize` / provider-access lifecycle no longer exists; the
/// equivalent validation now lives on `RainSdk.builder().build()`. Portal-specific init
/// validation (empty session token, RPC config) moved to `RainPortalTests`.
@Suite("SDK Initialization Tests")
struct SDKInitializationTests {

  /// Minimal `ProviderDescriptor` so the builder has something to register — resolving it yields a
  /// `StubWalletProvider`. Lets these tests exercise builder validation without a vendor SDK.
  private struct StubProvider: ProviderDescriptor {
    var id: ProviderId = .turnkey
    var capabilities: Set<Capability> = []
    func create(context: ProviderContext) async throws -> any WalletProvider {
      StubWalletProvider()
    }
  }

  /// A descriptor that counts `close()` calls through a shared box, like the real adapters whose
  /// struct copies share one coordinator.
  private final class CloseCounter: @unchecked Sendable { var count = 0 }
  private struct ClosableProvider: ProviderDescriptor {
    var id: ProviderId = .turnkey
    let counter: CloseCounter
    func create(context: ProviderContext) async throws -> any WalletProvider { StubWalletProvider() }
    func close() { counter.count += 1 }
  }

  // MARK: - builder() validation

  @Test("build succeeds with valid configs and a registered provider")
  func testBuildSuccess() throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([
        NetworkConfig.testConfig(chainId: 1, rpcUrl: "https://mainnet.infura.io/v3/test"),
        NetworkConfig.testConfig(chainId: 137, rpcUrl: "https://polygon-rpc.com")
      ])
      .register(StubProvider())
      .build()
    #expect(sdk.providerIds.contains(.turnkey))
  }

  /// Runs `body`, expecting `.invalidConfig` whose details equal `expectedDetails`.
  private func expectInvalidConfig(
    details expectedDetails: String,
    _ body: () throws -> Void
  ) {
    do {
      try body()
      Issue.record("Expected invalidConfig, but no error was thrown")
    } catch let error as RainError {
      guard case .invalidConfig(let details) = error else {
        Issue.record("Expected .invalidConfig, got \(error)")
        return
      }
      #expect(details == expectedDetails)
    } catch {
      Issue.record("Expected RainError.invalidConfig, got \(error)")
    }
  }

  @Test("build throws invalidConfig for empty configs")
  func testBuildEmptyConfigs() throws {
    expectInvalidConfig(details: "At least one RPC endpoint is required") {
      _ = try RainSdk.builder().register(StubProvider()).build()
    }
  }

  @Test("build throws invalidConfig for zero chain ID")
  func testBuildInvalidChainIdZero() throws {
    expectInvalidConfig(details: "Invalid RPC endpoint for chainId 0: https://test-rpc.com") {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 0)])
        .register(StubProvider())
        .build()
    }
  }

  @Test("build throws invalidConfig for negative chain ID")
  func testBuildInvalidChainIdNegative() throws {
    expectInvalidConfig(details: "Invalid RPC endpoint for chainId -1: https://test-rpc.com") {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: -1)])
        .register(StubProvider())
        .build()
    }
  }

  @Test("build throws invalidConfig for empty RPC URL")
  func testBuildEmptyRpcUrl() throws {
    expectInvalidConfig(details: "Invalid RPC URL for chainId 1, an https URL is required: ") {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 1, rpcUrl: "")])
        .register(StubProvider())
        .build()
    }
  }

  @Test("build throws invalidConfig for URL without scheme")
  func testBuildRpcUrlMissingScheme() throws {
    expectInvalidConfig(details: "Invalid RPC URL for chainId 1, an https URL is required: not-a-valid-url") {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 1, rpcUrl: "not-a-valid-url")])
        .register(StubProvider())
        .build()
    }
  }

  @Test("build throws invalidConfig for non-HTTP scheme")
  func testBuildRpcUrlNonHttpScheme() throws {
    expectInvalidConfig(details: "Invalid RPC URL for chainId 1, an https URL is required: ftp://example.com") {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 1, rpcUrl: "ftp://example.com")])
        .register(StubProvider())
        .build()
    }
  }

  @Test("build refuses plain http unless the host is loopback")
  func testBuildRpcUrlPlainHttp() throws {
    expectInvalidConfig(details: "Invalid RPC URL for chainId 1, an https URL is required: http://rpc.test") {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 1, rpcUrl: "http://rpc.test")])
        .register(StubProvider())
        .build()
    }
    for url in ["http://127.0.0.1:8545", "http://[::1]:8545", "http://LOCALHOST:8545", "HTTPS://rpc.test"] {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 1, rpcUrl: url)])
        .register(StubProvider())
        .build()
    }
  }

  @Test("build with no provider succeeds (wallet-agnostic) but resolving a provider throws")
  func testBuildNoProvider() async throws {
    // Building with no registered provider is allowed — it yields a wallet-agnostic RainSdk whose
    // transaction-building methods work; resolving a provider is what throws.
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .build()

    await #expect(throws: RainError.providerNotRegistered(details: "No provider registered for id 'portal'")) {
      _ = try await sdk.provider(.portal)
    }
  }

  // MARK: - Provider resolution

  @Test("provider(_:) throws providerNotRegistered for an unregistered id")
  func testResolveUnregisteredProvider() async throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(StubProvider())
      .build()

    await #expect(throws: RainError.providerNotRegistered(details: "No provider registered for id 'privy'")) {
      _ = try await sdk.provider(.privy)
    }
  }

  @Test("rpcEndpoints([chainId: rpcUrl]) map form builds equivalent configs")
  func testBuildFromRpcMap() throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([1: "https://mainnet.com", 137: "https://polygon.com"])
      .register(StubProvider())
      .build()
    #expect(sdk.providerIds == [.turnkey])
  }

  // MARK: - Client metadata

  @Test("resolved client exposes providerId, capabilities and isInitialized")
  func testClientMetadata() async throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(StubProvider(capabilities: [.export, .recovery]))
      .build()

    let client = try await sdk.provider(.turnkey)
    #expect(client.providerId == .turnkey)
    #expect(client.capabilities == [.export, .recovery])
    #expect(client.isInitialized)
  }

  // MARK: - reset()

  @Test("reset evicts resolved clients; the SDK stays usable")
  func testReset() async throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(StubProvider())
      .build()

    let first = try await sdk.provider(.turnkey)

    sdk.reset()

    // The instance stays usable after reset: the next resolution re-runs create(context:)
    // and yields a fresh client.
    let second = try await sdk.provider(.turnkey)
    let firstIdentity = ObjectIdentifier(first as AnyObject)
    let secondIdentity = ObjectIdentifier(second as AnyObject)
    #expect(firstIdentity != secondIdentity)
  }

  @Test("close is terminal: providers are closed and every entry point throws sdkNotInitialized")
  func testCloseIsTerminal() async throws {
    let counter = CloseCounter()
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(ClosableProvider(counter: counter))
      .build()
    _ = try await sdk.provider(.turnkey)

    sdk.close()
    sdk.close() // idempotent

    #expect(counter.count == 2)
    await #expect(throws: RainError.sdkNotInitialized) { _ = try await sdk.provider(.turnkey) }
    await #expect(throws: RainError.sdkNotInitialized) { _ = try await sdk.first { _ in true } }
    await #expect(throws: RainError.sdkNotInitialized) {
      _ = try await sdk.tokenMetadata(chainId: 1, address: TestFixtures.usdcAddress)
    }
    await #expect(throws: RainError.sdkNotInitialized) { try await sdk.registerTokens([]) }
  }

  @Test("build closes a descriptor that a re-register of the same id replaced, but not a copy of the live one")
  func testBuildClosesReplacedDescriptors() throws {
    let first = CloseCounter(), second = CloseCounter()
    let live = ClosableProvider(counter: second)
    _ = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(ClosableProvider(counter: first))
      .register(live)
      .register(live) // a copy of the live descriptor: shares its internals, must not be closed
      .build()

    #expect(first.count == 1)
    #expect(second.count == 0)
  }

  @Test("a failing build leaves replaced descriptors open")
  func testFailingBuildDoesNotClose() {
    let first = CloseCounter()
    #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try RainSdk.builder() // no RPC endpoints → invalid
        .register(ClosableProvider(counter: first))
        .register(ClosableProvider(counter: CloseCounter()))
        .build()
    }
    #expect(first.count == 0)
  }

  @Test("tokenMetadata throws invalidConfig for a chain without an RPC endpoint or a malformed address")
  func testTokenMetadataRefusesBadInput() async throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .build()

    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await sdk.tokenMetadata(chainId: 999, address: TestFixtures.usdcAddress)
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await sdk.tokenMetadata(chainId: 1, address: "0xnope")
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await sdk.tokenMetadata(chainId: 1, address: String(TestFixtures.usdcAddress.dropFirst(2)))
    }
    // A well-formed registry token still resolves.
    #expect(try await sdk.tokenMetadata(chainId: 1, address: TestFixtures.usdcAddress)?.decimals == 6)
  }

  @Test("registerTokens stores before returning and rejects a malformed list whole")
  func testRegisterTokensOrderedAndValidated() async throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .build()
    let foo = TokenInfo(chainId: 1, address: "0x00000000000000000000000000000000000000ff", symbol: "FOO", decimals: 12, name: nil)

    try await sdk.registerTokens([foo])
    #expect(try await sdk.tokenMetadata(chainId: 1, address: foo.address)?.symbol == "FOO")

    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await sdk.registerTokens([
        TokenInfo(chainId: 1, address: "0x00000000000000000000000000000000000000ee", symbol: "OK", decimals: 6, name: nil),
        TokenInfo(chainId: 1, address: "0x00000000000000000000000000000000000000dd", symbol: "BAD", decimals: 99, name: nil),
      ])
    }
    // (That nothing from the rejected list landed is pinned at the store level in
    // TokenMetadataStoreTests — checking it here would trigger an on-chain read.)
  }

  @Test("build rejects a malformed seed token")
  func testBuildRejectsBadSeedToken() {
    #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try RainSdk.builder()
        .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
        .registerTokens([TokenInfo(chainId: 1, address: "0xnope", symbol: "X", decimals: 6, name: nil)])
        .build()
    }
  }

  @Test("reset is idempotent and client-level reset is a safe no-op")
  func testResetIdempotent() async throws {
    let sdk = try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(StubProvider())
      .build()

    let client = try await sdk.provider(.turnkey)
    client.reset() // parity no-op; must not throw or corrupt the client
    _ = try await client.getWalletAddress()

    sdk.reset()
    sdk.reset()
    _ = try await sdk.provider(.turnkey)
  }

}
