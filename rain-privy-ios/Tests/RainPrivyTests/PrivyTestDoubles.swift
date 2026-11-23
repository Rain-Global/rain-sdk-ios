import Foundation
import PrivySDK
import RainCore
@testable import RainPrivy

// MARK: - PrivyWalletSource fakes

/// In-memory `PrivyWalletSource`: returns a configured wallet list (or nil = unauthenticated)
/// and counts lookups so tests can assert resolve-once behaviour.
final class FakeWalletSource: PrivyWalletSource, @unchecked Sendable {
  private let lock = NSLock()
  private var _lookups = 0
  private var _solanaLookups = 0
  private let wallets: [any PrivyEthereumSigner]?
  private let solanaWallets: [any PrivySolanaAccount]?
  private let lookupDelayNs: UInt64

  init(
    wallets: [any PrivyEthereumSigner]?,
    solanaWallets: [any PrivySolanaAccount]? = nil,
    lookupDelayNs: UInt64 = 0
  ) {
    self.wallets = wallets
    self.solanaWallets = solanaWallets
    self.lookupDelayNs = lookupDelayNs
  }

  var lookups: Int {
    lock.lock(); defer { lock.unlock() }
    return _lookups
  }

  /// Solana analogue of `lookups`.
  var solanaLookups: Int {
    lock.lock(); defer { lock.unlock() }
    return _solanaLookups
  }

  private func recordLookup() {
    lock.lock(); defer { lock.unlock() }
    _lookups += 1
  }

  private func recordSolanaLookup() {
    lock.lock(); defer { lock.unlock() }
    _solanaLookups += 1
  }

  func embeddedEthereumWallets() async -> [any PrivyEthereumSigner]? {
    recordLookup()
    if lookupDelayNs > 0 {
      try? await Task.sleep(nanoseconds: lookupDelayNs)
    }
    return wallets
  }

  func embeddedSolanaWallets() async -> [any PrivySolanaAccount]? {
    recordSolanaLookup()
    if lookupDelayNs > 0 {
      try? await Task.sleep(nanoseconds: lookupDelayNs)
    }
    return solanaWallets
  }
}

/// Recording `PrivySolanaAccount`: captures what was signed and for which cluster, and returns /
/// throws a configured result.
final class FakeSolanaAccount: PrivySolanaAccount, @unchecked Sendable {
  private let lock = NSLock()
  private var _sends: [(transaction: Data, caip2: String, rpcUrl: String)] = []
  private var _transactionCalls: [String] = []

  let address: String
  var sendResult: Result<String, Error>
  /// Results returned by successive `getTransactions` calls (consumed front-to-back; the last
  /// entry repeats if calls outnumber entries). A failure entry throws for that call.
  var transactionsResults: [Result<PrivyTransactionsPage, Error>] = [
    .success(PrivyTransactionsPage(transactions: [], nextCursor: nil))
  ]
  private var transactionsCallCount = 0

  init(address: String, sendResult: Result<String, Error> = .success("SIGNATURE")) {
    self.address = address
    self.sendResult = sendResult
  }

  var sends: [(transaction: Data, caip2: String, rpcUrl: String)] {
    lock.lock(); defer { lock.unlock() }
    return _sends
  }

  /// One recorded line per `getTransactions` call, describing the params it received.
  var transactionCalls: [String] {
    lock.lock(); defer { lock.unlock() }
    return _transactionCalls
  }

  func signAndSendTransaction(
    transaction: Data,
    caip2: String,
    rpcUrl: String
  ) async throws -> String {
    record((transaction, caip2, rpcUrl))
    return try sendResult.get()
  }

  func getTransactions(_ params: GetTransactionsParams) async throws -> PrivyTransactionsPage {
    let index = recordTransactionCall(
      "chain=\(params.chain)"
        + ",assets=\(params.assets?.joined(separator: "+") ?? "nil")"
        + ",tokens=\(params.tokens?.joined(separator: "+") ?? "nil")"
        + ",limit=\(params.limit.map(String.init) ?? "nil")"
        + ",cursor=\(params.cursor ?? "nil")"
    )
    return try transactionsResults[index].get()
  }

  private func recordTransactionCall(_ line: String) -> Int {
    lock.lock(); defer { lock.unlock() }
    _transactionCalls.append(line)
    let index = min(transactionsCallCount, transactionsResults.count - 1)
    transactionsCallCount += 1
    return index
  }

  private func record(_ send: (transaction: Data, caip2: String, rpcUrl: String)) {
    lock.lock(); defer { lock.unlock() }
    _sends.append(send)
  }
}

/// Recording `PrivyEthereumSigner`: appends every `switchChain` / `request` to `events`
/// (thread-safe) and returns / throws a configured result. An optional artificial delay inside
/// `request` widens race windows for the send-serialization test.
final class FakeSigner: PrivyEthereumSigner, @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [String] = []
  private var _requestParams: [[String]] = []

  let address: String
  var requestResult: Result<String, Error>
  var requestDelayNs: UInt64 = 0
  /// Results returned by successive `getTransactions` calls (consumed front-to-back; the last
  /// entry repeats if calls outnumber entries). A failure entry throws for that call.
  var transactionsResults: [Result<PrivyTransactionsPage, Error>] = [
    .success(PrivyTransactionsPage(transactions: [], nextCursor: nil))
  ]
  private var transactionsCallCount = 0

  init(address: String, requestResult: Result<String, Error> = .success("0xHASH")) {
    self.address = address
    self.requestResult = requestResult
  }

  var events: [String] {
    lock.lock(); defer { lock.unlock() }
    return _events
  }

  /// Raw params of each `request` call, so a test can assert calldata reaches Privy unchanged.
  var requestParams: [[String]] {
    lock.lock(); defer { lock.unlock() }
    return _requestParams
  }

  private func record(_ event: String) {
    lock.lock(); defer { lock.unlock() }
    _events.append(event)
  }

  func request(_ request: EthereumRpcRequest) async throws -> String {
    record("request:\(request.method)")
    lock.withLock { _requestParams.append(request.params) }
    if requestDelayNs > 0 {
      try? await Task.sleep(nanoseconds: requestDelayNs)
    }
    return try requestResult.get()
  }

  func switchChain(chainId: Int, rpcUrl: String?) async {
    record("switch:\(chainId)")
  }

  func getTransactions(_ params: GetTransactionsParams) async throws -> PrivyTransactionsPage {
    record(
      "getTransactions:chain=\(params.chain)"
        + ",assets=\(params.assets?.joined(separator: "+") ?? "nil")"
        + ",tokens=\(params.tokens?.joined(separator: "+") ?? "nil")"
        + ",limit=\(params.limit.map(String.init) ?? "nil")"
        + ",cursor=\(params.cursor ?? "nil")"
    )
    return try transactionsResults[nextTransactionsResultIndex()].get()
  }

  private func nextTransactionsResultIndex() -> Int {
    lock.lock(); defer { lock.unlock() }
    let index = min(transactionsCallCount, transactionsResults.count - 1)
    transactionsCallCount += 1
    return index
  }
}

// MARK: - Privy descriptor stub

/// Minimal `Privy` conformance for constructing a `PrivyConfig` in descriptor tests. Every member
/// traps — `PrivyProvider.id` / `.capabilities` never touch the vendor singleton.
final class UnimplementedPrivy: Privy, @unchecked Sendable {
  func awaitReady() async { fatalError("unimplemented") }
  func getAuthState() async -> AuthState { fatalError("unimplemented") }
  func getAuthStateWithoutRefresh() -> AuthState { fatalError("unimplemented") }
  var user: (any PrivyUser)? { fatalError("unimplemented") }
  func getUser() async -> (any PrivyUser)? { fatalError("unimplemented") }
  var authState: AuthState { fatalError("unimplemented") }
  var authStateStream: AsyncStream<AuthState> { fatalError("unimplemented") }
  var email: any LoginWithEmail { fatalError("unimplemented") }
  var sms: any LoginWithSms { fatalError("unimplemented") }
  var siwe: any LoginWithSiwe { fatalError("unimplemented") }
  var siws: any LoginWithSiws { fatalError("unimplemented") }
  var customJwt: any LoginWithCustomAccessToken { fatalError("unimplemented") }
  var oAuth: any LoginWithOAuth { fatalError("unimplemented") }
  var passkey: any LoginWithPasskey { fatalError("unimplemented") }
  var mfa: any PrivyMfa { fatalError("unimplemented") }
  func onNetworkRestored() async { fatalError("unimplemented") }
}

// MARK: - TokenMetadataStore access

/// `TokenMetadataStore`'s initializer is internal to RainCore, so tests obtain the real store the
/// same way adapters do: register a capturing provider on a throwaway `RainSdk` and grab the
/// store from the `ProviderContext` handed to `create(context:)`.
enum TestTokenStore {
  private final class Box: @unchecked Sendable {
    var store: TokenMetadataStore?
  }

  private struct CapturingProvider: ProviderDescriptor {
    let box: Box
    var id: ProviderId { ProviderId("test-capture") }
    var capabilities: Set<Capability> { [] }
    func create(context: ProviderContext) async throws -> any WalletProvider {
      box.store = context.tokenStore
      return NullWalletProvider()
    }
  }

  private struct NullWalletProvider: WalletProvider {
    func address() async throws -> String { throw RainError.walletUnavailable() }
    func sendTransaction(chainId: Int, params: WalletTransactionParams) async throws -> String {
      throw RainError.walletUnavailable()
    }
    func getBalance(chainId: Int, token: Token) async throws -> Balance {
      throw RainError.walletUnavailable()
    }
    func getBalances(chainId: Int) async throws -> [Balance] {
      throw RainError.walletUnavailable()
    }
    func getTransactions(
      chainId: Int, limit: Int?, offset: Int?, order: RainTransactionOrder?
    ) async throws -> [RainTransaction] {
      throw RainError.walletUnavailable()
    }
  }

  /// Builds a real `TokenMetadataStore` seeded with `tokens`.
  static func make(chainId: Int, rpcUrl: String, tokens: [TokenInfo]) async throws -> TokenMetadataStore {
    let box = Box()
    let sdk = try RainSdk.builder()
      .rpcEndpoints([chainId: rpcUrl])
      .register(CapturingProvider(box: box))
      .registerTokens(tokens)
      .build()
    _ = try await sdk.provider(ProviderId("test-capture"))
    guard let store = box.store else {
      throw RainError.internalError(details: "token store was not captured")
    }
    return store
  }
}

// MARK: - Stubbed JSON-RPC transport

/// URLProtocol stub for `PrivyRpcClient`'s URLSession. Routes by request host so concurrently
/// running suites don't clobber each other's handlers.
final class StubURLProtocol: URLProtocol {
  /// host → handler(parsed JSON-RPC body) → HTTP body data
  nonisolated(unsafe) private static var handlers: [String: @Sendable ([String: Any]) -> Data] = [:]
  private static let lock = NSLock()

  static func setHandler(host: String, _ handler: @escaping @Sendable ([String: Any]) -> Data) {
    lock.lock(); defer { lock.unlock() }
    handlers[host] = handler
  }

  private static func handler(host: String) -> (@Sendable ([String: Any]) -> Data)? {
    lock.lock(); defer { lock.unlock() }
    return handlers[host]
  }

  /// A URLSession whose every request is served by the registered handlers.
  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let host = request.url?.host, let handler = Self.handler(host: host) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }

    let body = Self.bodyData(of: request)
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let responseData = handler(json)

    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: responseData)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// URLSession delivers POST bodies via `httpBodyStream`, not `httpBody` — drain it.
  private static func bodyData(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}

// MARK: - JSON-RPC response helpers

enum RpcStub {
  static func result(_ value: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": value])
  }

  static func error(code: Int, message: String) -> Data {
    try! JSONSerialization.data(
      withJSONObject: ["jsonrpc": "2.0", "id": 1, "error": ["code": code, "message": message]]
    )
  }

  static func rawResult(_ value: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": value])
  }

  /// Pulls the `to` address out of an `eth_call` params list (first param is the call object).
  static func callTarget(_ body: [String: Any]) -> String? {
    let params = body["params"] as? [Any]
    return (params?.first as? [String: Any])?["to"] as? String
  }
}
