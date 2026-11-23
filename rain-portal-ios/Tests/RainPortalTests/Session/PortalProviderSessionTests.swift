import Foundation
@testable import PortalSwift
@_spi(RainAdapter) @testable import RainCore
@testable import RainPortal
import Testing

/// Session hardening wired end to end through `PortalProvider`: a rejected token re-mints via
/// `onSessionTokenNeeded`, rebuilds the vendor client with the retained RPC config, and retries
/// the wallet call; a declined re-mint fires `onSessionExpired`.
@Suite("Portal Provider Session Tests")
struct PortalProviderSessionTests {

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
  }

  /// Records every factory call and vends a scripted client per token.
  private final class FactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: MockPortal]
    private var recorded: [(token: String, rpcConfig: [String: String])] = []
    var calls: [(token: String, rpcConfig: [String: String])] { lock.withLock { recorded } }

    init(_ clients: [String: MockPortal]) { self.clients = clients }

    func build(_ token: String, _ rpcConfig: [String: String]) throws -> PortalRequestProtocol {
      lock.withLock { recorded.append((token, rpcConfig)) }
      guard let client = lock.withLock({ clients[token] }) else {
        throw RainError.internalError(details: "no client scripted for \(token)")
      }
      return client
    }
  }

  private func makeContext(configs: [NetworkConfig] = TestFixtures.configs()) -> ProviderContext {
    let reader = EVMChainReader(networkConfigs: configs)
    return ProviderContext(
      rpcEndpoints: Dictionary(uniqueKeysWithValues: configs.map { ($0.chainId, $0.rpcUrl) }),
      networkConfigs: configs,
      tokenStore: TokenMetadataStore(chainReader: reader),
      transactionBuilder: MockTransactionBuilderService(networkConfigs: configs),
      evmChainReader: reader
    )
  }

  private func rejectingPortal() -> MockPortal {
    let portal = MockPortal()
    portal.addressesError = PortalRequestsError.unauthorized
    return portal
  }

  private func portalWith(address: String) -> MockPortal {
    let portal = MockPortal()
    portal.setMockAddress(address, forNamespace: .eip155)
    return portal
  }

  @Test("rejected token is re-minted, the client rebuilt with the retained RPC config, and the call retried")
  func refreshRebuildsAndRetries() async throws {
    let fresh = portalWith(address: "0xfresh")
    let factory = FactoryRecorder(["dead": rejectingPortal(), "fresh": fresh])
    let expired = Counter()
    let provider = PortalProvider(
      PortalConfig(
        sessionToken: "dead",
        onSessionTokenNeeded: { "fresh" },
        onSessionExpired: { expired.increment() }
      ),
      onPortalCreated: nil,
      portalFactory: factory.build
    )
    let wallet = try await provider.create(context: makeContext())

    let address = try await wallet.address()

    #expect(address == "0xfresh")
    #expect(expired.value == 0)
    #expect(provider.currentSessionState() == .active)
    let calls = factory.calls
    #expect(calls.map(\.token) == ["dead", "fresh"])
    #expect(calls.last?.rpcConfig == PortalProvider.portalRpcConfig(from: TestFixtures.configs()))
  }

  @Test("declined re-mint surfaces tokenExpired and fires onSessionExpired once")
  func declinedRefresh() async throws {
    let factory = FactoryRecorder(["dead": rejectingPortal()])
    let expired = Counter()
    let provider = PortalProvider(
      PortalConfig(
        sessionToken: "dead",
        onSessionTokenNeeded: { nil },
        onSessionExpired: { expired.increment() }
      ),
      onPortalCreated: nil,
      portalFactory: factory.build
    )
    let wallet = try await provider.create(context: makeContext())

    for _ in 0..<2 {
      await #expect(throws: RainError.tokenExpired) {
        _ = try await wallet.address()
      }
    }
    #expect(expired.value == 1)
    #expect(factory.calls.map(\.token) == ["dead"])
    #expect(provider.currentSessionState() == .expired)
  }

  @Test("updateSessionToken swaps the client used by later calls")
  func updateSessionToken() async throws {
    let factory = FactoryRecorder(["one": portalWith(address: "0xone"), "two": portalWith(address: "0xtwo")])
    let provider = PortalProvider(
      PortalConfig(sessionToken: "one"),
      onPortalCreated: nil,
      portalFactory: factory.build
    )
    let wallet = try await provider.create(context: makeContext())
    #expect(try await wallet.address() == "0xone")

    try await provider.updateSessionToken("two")

    #expect(try await wallet.address() == "0xtwo")
    #expect(factory.calls.map(\.token) == ["one", "two"])
  }

  @Test("refreshSession and updateSessionToken before create fail as sdkNotInitialized and stay silent")
  func refreshBeforeCreate() async throws {
    let expired = Counter()
    let provider = PortalProvider(
      PortalConfig(
        sessionToken: "one",
        onSessionTokenNeeded: { "two" },
        onSessionExpired: { expired.increment() }
      ),
      onPortalCreated: nil,
      portalFactory: FactoryRecorder([:]).build
    )
    await #expect(throws: RainError.sdkNotInitialized) {
      try await provider.refreshSession()
    }
    await #expect(throws: RainError.sdkNotInitialized) {
      try await provider.updateSessionToken("two")
    }
    #expect(expired.value == 0)
    #expect(provider.currentSessionState() == .unknown)
  }

  @Test("a send rejected on the pre-flight is retried once on the rebuilt client")
  func sendRetriesOnRebuiltClient() async throws {
    let chain = ChainIDFormat.EIP155.format(chainId: TestFixtures.configs()[0].chainId)
    let dead = MockPortal()
    dead.setMockResponse(chainId: chain, method: .eth_call, error: PortalRequestsError.unauthorized)
    let fresh = MockPortal()
    let factory = FactoryRecorder(["dead": dead, "fresh": fresh])
    let created = Counter()
    let provider = PortalProvider(
      PortalConfig(sessionToken: "dead", onSessionTokenNeeded: { "fresh" }),
      onPortalCreated: { _ in created.increment() },
      portalFactory: factory.build
    )
    let wallet = try await provider.create(context: makeContext())

    let hash = try await wallet.sendTransaction(
      chainId: TestFixtures.configs()[0].chainId,
      params: WalletTransactionParams(from: "0xfrom", to: "0xto", value: "0x0", data: "0x")
    )

    #expect(hash == "0x" + String(repeating: "a", count: 64))
    #expect(dead.requestCalls.map(\.method) == [.eth_call])
    // eth_call preflights the send; eth_blockNumber bounds the UserOperation scan that follows it.
    #expect(fresh.requestCalls.map(\.method) == [.eth_call, .eth_blockNumber, .eth_sendTransaction])
    // onPortalCreated only fires for concrete Portal instances; mocks are not, so none here.
    #expect(created.value == 0)
  }

  @Test("close silences the expiry hook")
  func closeSilences() async throws {
    let factory = FactoryRecorder(["dead": rejectingPortal()])
    let expired = Counter()
    let provider = PortalProvider(
      PortalConfig(sessionToken: "dead", onSessionExpired: { expired.increment() }),
      onPortalCreated: nil,
      portalFactory: factory.build
    )
    let wallet = try await provider.create(context: makeContext())
    provider.close()
    await #expect(throws: RainError.tokenExpired) {
      _ = try await wallet.address()
    }
    #expect(expired.value == 0)
  }

  @Test("a factory failure at create surfaces as a RainError")
  func factoryFailureAtCreate() async throws {
    let provider = PortalProvider(
      PortalConfig(sessionToken: "broken"),
      onPortalCreated: nil,
      portalFactory: FactoryRecorder([:]).build
    )
    await #expect(throws: RainError.self) {
      _ = try await provider.create(context: makeContext())
    }
  }
}
