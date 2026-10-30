import Testing
import Foundation
import PrivySDK
import RainCore
@testable import RainPrivy

/// Wallet coverage: balance fault tolerance, zero-balance filtering, fee math, empty history,
/// and the send path (eth_call pre-simulation → switch → broadcast). The JSON-RPC read path runs
/// through a URLProtocol-stubbed `URLSession`, with one stub host per test so parallel tests
/// don't share handlers.
@Suite("Privy Wallet Provider Tests")
struct PrivyWalletProviderTests {
  private static let chainId = 31337
  private static let wallet = "0x000000000000000000000000000000000000dEaD"

  private static func tokens() -> [TokenInfo] {
    [
      TokenInfo(chainId: chainId, address: "0x00000000000000000000000000000000000000aa", symbol: "USDC", decimals: 6, name: "USD Coin"),
      TokenInfo(chainId: chainId, address: "0x00000000000000000000000000000000000000bb", symbol: "BAD", decimals: 18, name: "Bad"),
      TokenInfo(chainId: chainId, address: "0x00000000000000000000000000000000000000cc", symbol: "ZERO", decimals: 18, name: "Zero"),
    ]
  }

  /// Builds a provider whose RPC reads hit the stub registered for `host` and whose address is a
  /// fixed override (so the Privy source is never consulted for reads).
  private static func makeProvider(
    host: String,
    manager: PrivyManager = PrivyManager(source: FakeWalletSource(wallets: nil)),
    seedTokens: [TokenInfo] = tokens()
  ) async throws -> PrivyWalletProvider {
    let rpcUrl = "https://\(host)/"
    let store = try await TestTokenStore.make(chainId: chainId, rpcUrl: rpcUrl, tokens: seedTokens)
    return PrivyWalletProvider(
      manager: manager,
      rpcEndpoints: [chainId: rpcUrl],
      tokenStore: store,
      solanaSupport: RainSolanaSupport(
        networkConfigs: [NetworkConfig(chainId: chainId, rpcUrl: rpcUrl)],
        session: StubURLProtocol.makeSession()
      ),
      walletAddressOverride: wallet,
      rpcClient: PrivyRpcClient(session: StubURLProtocol.makeSession())
    )
  }

  // MARK: - Balances

  @Test("getBalances keeps native and healthy tokens when one token read fails, drops zero balances")
  func balancesFaultTolerantAndZeroFiltered() async throws {
    let host = "balances-ft.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      switch body["method"] as? String {
      case "eth_getBalance":
        return RpcStub.result("0x1")
      case "eth_call":
        switch RpcStub.callTarget(body) {
        case "0x00000000000000000000000000000000000000aa": return RpcStub.result("0x5")
        case "0x00000000000000000000000000000000000000cc": return RpcStub.result("0x0")
        default: return RpcStub.error(code: -32000, message: "rpc down for this token")
        }
      default:
        return RpcStub.error(code: -32601, message: "unexpected method")
      }
    }

    let provider = try await Self.makeProvider(host: host)
    let balances = try await provider.getBalances(chainId: Self.chainId)

    // Native + the non-zero USDC only; the failing token is dropped (not fatal), zero filtered.
    #expect(balances.map(\.token) == [.native, .contract(address: "0x00000000000000000000000000000000000000aa")])
    #expect(balances[1].rawAmount.description == "5")
  }

  @Test("getBalances propagates a native balance failure")
  func nativeFailurePropagates() async throws {
    let host = "balances-native-fail.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: -32000, message: "node down")
    }

    let provider = try await Self.makeProvider(host: host)
    await #expect(throws: RainError.self) {
      _ = try await provider.getBalances(chainId: Self.chainId)
    }
  }

  @Test("getBalance native reads eth_getBalance with exact wei precision")
  func nativeBalanceExact() async throws {
    let host = "balance-native.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      body["method"] as? String == "eth_getBalance"
        ? RpcStub.result("0x0de0b6b3a7640000") // 1 ETH in wei
        : RpcStub.error(code: -32601, message: "unexpected method")
    }

    let provider = try await Self.makeProvider(host: host)
    let balance = try await provider.getBalance(chainId: Self.chainId, token: .native)

    #expect(balance.token == .native)
    #expect(balance.rawAmount.description == "1000000000000000000")
  }

  @Test("getBalance contract resolves registered metadata")
  func contractBalanceMetadata() async throws {
    let host = "balance-contract.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      body["method"] as? String == "eth_call"
        ? RpcStub.result("0xf4240") // 1_000_000 base units
        : RpcStub.error(code: -32601, message: "unexpected method")
    }

    let provider = try await Self.makeProvider(host: host)
    let balance = try await provider.getBalance(
      chainId: Self.chainId, token: .contract(address: "0x00000000000000000000000000000000000000aa"))

    #expect(balance.rawAmount.description == "1000000")
    #expect(balance.decimals == 6)
    #expect(balance.symbol == "USDC")
  }

  // MARK: - Fees

  @Test("estimateTransactionFee multiplies gas limit by gas price")
  func feeEstimateMath() async throws {
    let host = "fee.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      switch body["method"] as? String {
      case "eth_estimateGas": return RpcStub.result("0x5208")     // 21000
      case "eth_gasPrice": return RpcStub.result("0x3b9aca00")    // 1 gwei
      default: return RpcStub.error(code: -32601, message: "unexpected method")
      }
    }

    let provider = try await Self.makeProvider(host: host)
    let fee = try await provider.estimateTransactionFee(
      chainId: Self.chainId,
      walletAddress: Self.wallet,
      params: WalletTransactionParams(from: Self.wallet, to: "0xTO", value: "0x0", data: "0x")
    )

    // 21000 * 1e9 wei = 2.1e13 wei = exactly 0.000021 ETH
    #expect(fee == Decimal(string: "0.000021"))
  }

  // MARK: - Send path

  @Test("sendTransaction simulates via eth_call, then switches chain and broadcasts")
  func sendSimulatesThenBroadcasts() async throws {
    let host = "send-happy.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      body["method"] as? String == "eth_call"
        ? RpcStub.result("0x")
        : RpcStub.error(code: -32601, message: "unexpected method")
    }

    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xHASH"))
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))
    let provider = try await Self.makeProvider(host: host, manager: manager)

    let hash = try await provider.sendTransaction(
      chainId: Self.chainId,
      params: WalletTransactionParams(from: Self.wallet, to: "0xTO", value: "0x1", data: "0x")
    )

    #expect(hash == "0xHASH")
    #expect(signer.events == ["switch:\(Self.chainId)", "request:eth_sendTransaction"])
  }

  @Test("ERC-20 approve calldata reaches Privy unchanged through the generic send path")
  func approveCalldataBroadcastsUnchanged() async throws {
    let host = "send-approve.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      body["method"] as? String == "eth_call"
        ? RpcStub.result("0x")
        : RpcStub.error(code: -32601, message: "unexpected method")
    }

    // approve(0x5a6E…8f29, uint256 max) — the Auth Pull approval.
    let approveCalldata = "0x095ea7b3"
      + "0000000000000000000000005a6e6b0d5ea051cfff9b3dcc2aa8dac226458f29"
      + String(repeating: "f", count: 64)
    let token = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"

    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xAPPROVEHASH"))
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))
    let provider = try await Self.makeProvider(host: host, manager: manager)

    let hash = try await provider.sendTransaction(
      chainId: Self.chainId,
      params: WalletTransactionParams(
        from: Self.wallet, to: token, value: "0x0", data: approveCalldata)
    )

    #expect(hash == "0xAPPROVEHASH")
    #expect(signer.events == ["switch:\(Self.chainId)", "request:eth_sendTransaction"])
    let broadcast = try #require(signer.requestParams.first?.first)
    #expect(broadcast.contains(approveCalldata))
    #expect(broadcast.contains(token))
  }

  @Test("a failing eth_call simulation surfaces as transactionSimulationFailed without broadcasting")
  func simulationFailureBlocksBroadcast() async throws {
    let host = "send-sim-fail.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: 3, message: "execution reverted")
    }

    let signer = FakeSigner(address: Self.wallet)
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))
    let provider = try await Self.makeProvider(host: host, manager: manager)

    await #expect(throws: RainError.transactionSimulationFailed(underlying: NSError(domain: "", code: 0))) {
      _ = try await provider.sendTransaction(
        chainId: Self.chainId,
        params: WalletTransactionParams(from: Self.wallet, to: "0xTO", value: "0x1", data: "0x")
      )
    }
    #expect(signer.events.isEmpty) // nothing was broadcast
  }

  // MARK: - History / config

  /// A chain id Privy's transaction indexer supports. Sepolia specifically: it has no entries in
  /// RainCore's default token registry, so `registeredTokens` is exactly what a test seeds.
  private static let indexedChainId = 11_155_111

  /// Builds a provider around `signer` for transaction-history tests, with `tokens` seeded into
  /// the token store (each registered token adds a token-filter history query). History never
  /// touches the RPC client, so it is inert.
  private static func makeHistoryProvider(
    signer: FakeSigner,
    tokens: [TokenInfo] = []
  ) async throws -> PrivyWalletProvider {
    let rpcUrl = "https://history-unused.rpc/"
    let store = try await TestTokenStore.make(chainId: indexedChainId, rpcUrl: rpcUrl, tokens: tokens)
    return PrivyWalletProvider(
      manager: PrivyManager(source: FakeWalletSource(wallets: [signer])),
      rpcEndpoints: [indexedChainId: rpcUrl],
      tokenStore: store,
      solanaSupport: RainSolanaSupport(networkConfigs: []),
      rpcClient: PrivyRpcClient(session: StubURLProtocol.makeSession())
    )
  }

  // privyTransactionId defaults to nil so fixtures dedupe by their distinct hashes.
  private static func indexedTransaction(
    hash: String? = "0xHASH",
    createdAt: Int = 1_700_000_000_000,
    status: String = "confirmed",
    privyTransactionId: String? = nil,
    details: PrivyIndexedTransaction.Details? = indexedDetails()
  ) -> PrivyIndexedTransaction {
    PrivyIndexedTransaction(
      caip2: "eip155:1",
      transactionHash: hash,
      userOperationHash: nil,
      status: status,
      createdAt: createdAt,
      sponsored: false,
      privyTransactionId: privyTransactionId,
      walletId: "wallet-id",
      details: details
    )
  }

  private static func indexedDetails(
    asset: String = "eth",
    rawValue: String = "1500000000000000000",
    rawValueDecimals: Int = 18,
    displayValues: [String: String] = [:]
  ) -> PrivyIndexedTransaction.Details {
    PrivyIndexedTransaction.Details(
      type: "transferSent",
      sender: wallet,
      recipient: "0x1111111111111111111111111111111111111111",
      asset: asset,
      rawValue: rawValue,
      rawValueDecimals: rawValueDecimals,
      displayValues: displayValues
    )
  }

  @Test("getTransactions returns empty for a chain Privy does not index without calling Privy")
  func historyUnsupportedChainEmpty() async throws {
    let signer = FakeSigner(address: Self.wallet)
    let provider = try await Self.makeProvider(
      host: "history-unsupported.rpc",
      manager: PrivyManager(source: FakeWalletSource(wallets: [signer]))
    )
    // 31337 is not a chain Privy indexes.
    let transactions = try await provider.getTransactions(
      chainId: Self.chainId, limit: nil, offset: nil, order: nil)
    #expect(transactions.isEmpty)
    #expect(signer.events.isEmpty)
  }

  @Test("getTransactions maps Privy transactions onto the Rain model")
  func historyMapsFields() async throws {
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [Self.indexedTransaction(privyTransactionId: "privy-tx-id")],
        nextCursor: nil
      ))
    ]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)

    let tx = try #require(transactions.first)
    #expect(transactions.count == 1)
    #expect(tx.hash == "0xHASH")
    #expect(tx.uniqueId == "privy-tx-id")
    #expect(tx.from == Self.wallet)
    #expect(tx.to == "0x1111111111111111111111111111111111111111")
    #expect(tx.value == 1.5)
    #expect(tx.asset == "eth")
    #expect(tx.category == .external)
    #expect(tx.tokenAddress == nil)
    #expect(tx.rawValue == nil)
    #expect(tx.chainId == Self.indexedChainId)
    #expect(tx.timestamp == "2023-11-14T22:13:20Z")
    // Indexer metadata carries through into the row's metadata map.
    #expect(tx.metadata?.caip2 == "eip155:1")
    #expect(tx.metadata?.status == "confirmed")
    #expect(tx.metadata?.sponsored == false)
    #expect(tx.metadata?.privyTransactionId == "privy-tx-id")
    #expect(tx.metadata?.userOperationHash == nil)
    #expect(tx.metadata?.type == "transferSent")
    // Empty display values are omitted, not exposed as an empty map.
    #expect(tx.metadata?.displayValues == nil)
  }

  @Test("getTransactions exposes displayValues when the indexer supplies them")
  func historyDisplayValues() async throws {
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [Self.indexedTransaction(
          details: Self.indexedDetails(displayValues: ["eth": "1.5", "usd": "5000.25"])
        )],
        nextCursor: nil
      ))
    ]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)

    let tx = try #require(transactions.first)
    #expect(tx.metadata?.displayValues == ["eth": "1.5", "usd": "5000.25"])
  }

  @Test("getTransactions routes a contract-address asset into rawContract as erc20")
  func historyTokenTransfer() async throws {
    let contract = "0x2222222222222222222222222222222222222222"
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [
          Self.indexedTransaction(
            details: Self.indexedDetails(asset: contract, rawValue: "1500000", rawValueDecimals: 6))
        ],
        nextCursor: nil
      ))
    ]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)

    let tx = try #require(transactions.first)
    #expect(tx.asset == nil)
    #expect(tx.category == .erc20)
    #expect(tx.tokenAddress == contract)
    #expect(tx.rawValue == "1500000")
    #expect(tx.decimals == 6)
    #expect(tx.value == 1.5)
  }

  @Test("getTransactions falls back through userOperationHash and privyTransactionId for pending rows")
  func historyPendingHashFallback() async throws {
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [
          Self.indexedTransaction(hash: nil, status: "pending", privyTransactionId: "privy-tx-9")
        ],
        nextCursor: nil
      ))
    ]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)

    let tx = try #require(transactions.first)
    #expect(tx.hash == "privy-tx-9")
  }

  @Test("getTransactions follows the cursor until offset plus limit rows are collected, then slices")
  func historyCursorPaging() async throws {
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: (0..<3).map { Self.indexedTransaction(hash: "0xA\($0)", createdAt: 5_000 - $0) },
        nextCursor: "cursor-1"
      )),
      .success(PrivyTransactionsPage(
        transactions: (0..<2).map { Self.indexedTransaction(hash: "0xB\($0)", createdAt: 2_000 - $0) },
        nextCursor: "cursor-2"
      )),
    ]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: 3, offset: 2, order: nil)

    // Needs 5 rows: page one (3 rows, limit 5) then page two via cursor (2 rows, limit 2).
    #expect(signer.events == [
      "getTransactions:chain=sepolia,assets=eth,tokens=nil,limit=5,cursor=nil",
      "getTransactions:chain=sepolia,assets=eth,tokens=nil,limit=2,cursor=cursor-1",
    ])
    // Newest-first by default; offset 2 drops the two newest, limit 3 keeps the rest.
    #expect(transactions.map(\.hash) == ["0xA2", "0xB0", "0xB1"])
  }

  @Test("getTransactions stops paging when history is exhausted and honors ASC order")
  func historyAscOrder() async throws {
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [
          Self.indexedTransaction(hash: "0xNEW", createdAt: 2_000),
          Self.indexedTransaction(hash: "0xOLD", createdAt: 1_000),
        ],
        nextCursor: nil
      ))
    ]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: 10, offset: nil, order: .ASC)

    #expect(signer.events.count == 1)
    #expect(transactions.map(\.hash) == ["0xOLD", "0xNEW"])
  }

  @Test("getTransactions propagates Privy failures")
  func historyErrorPropagates() async throws {
    struct IndexerDown: Error {}
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [.failure(IndexerDown())]

    let provider = try await Self.makeHistoryProvider(signer: signer)
    await #expect(throws: IndexerDown.self) {
      _ = try await provider.getTransactions(
        chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)
    }
  }

  @Test("getTransactions merges native and registered-token history and dedupes overlapping rows")
  func historyMergesTokenQueries() async throws {
    let contract = "0x2222222222222222222222222222222222222222"
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [Self.indexedTransaction(hash: "0xNATIVE", createdAt: 3_000)],
        nextCursor: nil
      )),
      .success(PrivyTransactionsPage(
        transactions: [
          Self.indexedTransaction(hash: "0xTOKEN", createdAt: 2_000),
          Self.indexedTransaction(hash: "0xNATIVE", createdAt: 3_000),
        ],
        nextCursor: nil
      )),
    ]

    let usdc = TokenInfo(
      chainId: Self.indexedChainId, address: contract, symbol: "USDC", decimals: 6, name: "USD Coin")
    let provider = try await Self.makeHistoryProvider(signer: signer, tokens: [usdc])
    let transactions = try await provider.getTransactions(
      chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)

    // One native-asset query plus one token-address query; the duplicate row appears once.
    #expect(signer.events == [
      "getTransactions:chain=sepolia,assets=eth,tokens=nil,limit=10,cursor=nil",
      "getTransactions:chain=sepolia,assets=nil,tokens=\(contract),limit=10,cursor=nil",
    ])
    #expect(transactions.map(\.hash) == ["0xNATIVE", "0xTOKEN"])
  }

  @Test("getTransactions fails the whole call when a token query fails instead of returning partial history")
  func historyTokenQueryFailureFailsCall() async throws {
    // The raw error bubbles up (like the native query) so `RainError.from` classifies it via
    // the registered PrivyErrorMapping at the SDK boundary; no partial rows are returned.
    struct TokenFilterRejected: Error {}
    let contract = "0x2222222222222222222222222222222222222222"
    let signer = FakeSigner(address: Self.wallet)
    signer.transactionsResults = [
      .success(PrivyTransactionsPage(
        transactions: [Self.indexedTransaction(hash: "0xNATIVE")],
        nextCursor: nil
      )),
      .failure(TokenFilterRejected()),
    ]

    let usdc = TokenInfo(
      chainId: Self.indexedChainId, address: contract, symbol: "USDC", decimals: 6, name: "USD Coin")
    let provider = try await Self.makeHistoryProvider(signer: signer, tokens: [usdc])
    await #expect(throws: TokenFilterRejected.self) {
      _ = try await provider.getTransactions(
        chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)
    }
  }

  @Test("getTransactions surfaces a not-logged-in Privy session as tokenExpired")
  func historyNotLoggedInSurfacesTokenExpired() async throws {
    // `PrivySDK.PrivyError` has no public initializer, so the not-logged-in case is exercised
    // through the manager's wallet resolution, which throws the same `.tokenExpired` that
    // PrivyErrorMapping produces for authenticationFailure(.notLoggedIn).
    let rpcUrl = "https://history-not-logged-in.rpc/"
    let store = try await TestTokenStore.make(chainId: Self.indexedChainId, rpcUrl: rpcUrl, tokens: [])
    let provider = PrivyWalletProvider(
      manager: PrivyManager(source: FakeWalletSource(wallets: nil)),
      rpcEndpoints: [Self.indexedChainId: rpcUrl],
      tokenStore: store,
      solanaSupport: RainSolanaSupport(networkConfigs: []),
      rpcClient: PrivyRpcClient(session: StubURLProtocol.makeSession())
    )

    await #expect(throws: RainError.tokenExpired) {
      _ = try await provider.getTransactions(
        chainId: Self.indexedChainId, limit: nil, offset: nil, order: nil)
    }
  }

  @Test("an unconfigured chain id surfaces invalidConfig")
  func missingRpcEndpoint() async throws {
    let provider = try await Self.makeProvider(host: "missing-rpc.rpc")
    await #expect(throws: RainError.invalidConfig(details: "No RPC endpoint configured for chainId=999")) {
      _ = try await provider.getBalance(chainId: 999, token: .native)
    }
  }

  @Test("address override is returned without consulting Privy")
  func addressOverride() async throws {
    let source = FakeWalletSource(wallets: nil)
    let provider = try await Self.makeProvider(
      host: "address-override.rpc", manager: PrivyManager(source: source))
    #expect(try await provider.address() == Self.wallet)
    #expect(source.lookups == 0)
  }
}

/// Solana coverage: a Solana chain id must resolve the Solana account, read SOL over Solana
/// JSON-RPC (never `eth_getBalance`) and send through Privy's Solana signer. EVM-shaped writes
/// and SPL transfers fail fast.
@Suite("Privy Solana Tests")
struct PrivySolanaTests {
  private static let chainId = RainChain.solanaDevnet
  /// Valid base58, 32-byte address (the wrapped-SOL mint) so the reader's validation passes.
  private static let solanaAddress = "So11111111111111111111111111111111111111112"
  private static let evmWallet = "0x000000000000000000000000000000000000dEaD"

  /// Provider on a Solana cluster stubbed at `host`. The EVM override proves it is unused here.
  private static func makeProvider(
    host: String,
    source: FakeWalletSource
  ) async throws -> PrivyWalletProvider {
    let rpcUrl = "https://\(host)/"
    let store = try await TestTokenStore.make(chainId: chainId, rpcUrl: rpcUrl, tokens: [])
    return PrivyWalletProvider(
      manager: PrivyManager(source: source),
      rpcEndpoints: [chainId: rpcUrl],
      tokenStore: store,
      solanaSupport: RainSolanaSupport(
        networkConfigs: [NetworkConfig(chainId: chainId, rpcUrl: rpcUrl)],
        session: StubURLProtocol.makeSession()
      ),
      walletAddressOverride: evmWallet,
      rpcClient: PrivyRpcClient(session: StubURLProtocol.makeSession())
    )
  }

  private static func source(
    account: FakeSolanaAccount = FakeSolanaAccount(address: solanaAddress)
  ) -> FakeWalletSource {
    FakeWalletSource(wallets: nil, solanaWallets: [account])
  }

  /// Records the JSON-RPC methods / params the stub received.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(method: String, params: [Any])] = []
    var methods: [String] {
      lock.lock(); defer { lock.unlock() }
      return _calls.map(\.method)
    }
    var firstAddressParam: String? {
      lock.lock(); defer { lock.unlock() }
      return _calls.first?.params.first as? String
    }
    func record(_ body: [String: Any]) {
      lock.lock(); defer { lock.unlock() }
      _calls.append((body["method"] as? String ?? "", body["params"] as? [Any] ?? []))
    }
  }

  @Test("getBalance on Solana reads lamports via the Solana RPC using the embedded Solana address")
  func solanaNativeBalance() async throws {
    let host = "solana-balance.rpc"
    let recorder = Recorder()
    StubURLProtocol.setHandler(host: host) { body in
      recorder.record(body)
      guard body["method"] as? String == "getBalance" else {
        return RpcStub.error(code: -32601, message: "Method not found")
      }
      return RpcStub.rawResult(["context": ["slot": 1], "value": 1_500_000_000])
    }

    let provider = try await Self.makeProvider(host: host, source: Self.source())
    let balance = try await provider.getBalance(chainId: Self.chainId, token: .native)

    #expect(recorder.methods == ["getBalance"]) // never eth_getBalance
    #expect(recorder.firstAddressParam == Self.solanaAddress) // not the EVM override
    #expect(balance.rawAmount.description == "1500000000") // 1.5 SOL in lamports
    #expect(balance.decimals == 9)
    #expect(balance.symbol == "SOL")
    #expect(balance.chainId == Self.chainId)
  }

  @Test("getBalances on Solana lists native SOL plus every SPL token the wallet holds")
  func solanaGetBalances() async throws {
    let host = "solana-balances.rpc"
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    StubURLProtocol.setHandler(host: host) { body in
      switch body["method"] as? String {
      case "getBalance":
        return RpcStub.rawResult(["context": ["slot": 1], "value": 7])
      case "getTokenAccountsByOwner":
        // One query per token program; only the classic one holds anything here.
        let params = body["params"] as? [Any] ?? []
        let programId = (params.dropFirst().first as? [String: Any])?["programId"] as? String
        guard programId == Self.splTokenProgram else {
          return RpcStub.rawResult(["context": ["slot": 1], "value": []])
        }
        return RpcStub.rawResult(["context": ["slot": 1], "value": [[
          "pubkey": "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B",
          "account": ["data": ["parsed": ["info": [
            "mint": mint,
            "owner": Self.solanaAddress,
            "tokenAmount": ["amount": "2500000", "decimals": 6]
          ]]]]
        ]]])
      default:
        return RpcStub.error(code: -32601, message: "Method not found")
      }
    }

    let provider = try await Self.makeProvider(host: host, source: Self.source())
    let balances = try await provider.getBalances(chainId: Self.chainId)

    #expect(balances.map(\.token) == [.native, .contract(address: mint)])
    #expect(balances[0].rawAmount.description == "7")
    #expect(balances[1].rawAmount.description == "2500000")
    #expect(balances[1].decimals == 6)
  }

  @Test("getAddress returns the Solana account for Solana chains and the EVM address otherwise")
  func solanaAddressDispatch() async throws {
    let source = Self.source()
    let provider = try await Self.makeProvider(host: "solana-address.rpc", source: source)

    #expect(try await provider.getAddress(chainId: Self.chainId) == Self.solanaAddress)
    #expect(try await provider.getAddress(chainId: 43114) == Self.evmWallet)
    // Resolved once and cached across calls.
    _ = try await provider.getAddress(chainId: Self.chainId)
    #expect(source.solanaLookups == 1)
  }

  @Test("a user with no embedded Solana wallet surfaces walletUnavailable, not a bad RPC call")
  func solanaWalletMissing() async throws {
    let host = "solana-no-wallet.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: -32601, message: "Method not found")
    }
    let provider = try await Self.makeProvider(
      host: host, source: FakeWalletSource(wallets: nil, solanaWallets: []))

    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await provider.getBalance(chainId: Self.chainId, token: .native)
    }
  }

  @Test("an SPL token balance is read from the Solana RPC, never the EVM path")
  func solanaSplBalance() async throws {
    let host = "solana-spl.rpc"
    let recorder = Recorder()
    // The mint is read first (its program seeds the account derivation), then the wallet's
    // associated token account for it.
    let responses = Responder(queue: [
      RpcStub.rawResult(["context": ["slot": 1], "value": [
        "owner": Self.splTokenProgram,
        "data": ["parsed": ["type": "mint", "info": ["decimals": 6]]]
      ]]),
      RpcStub.rawResult(["context": ["slot": 1], "value": [
        "owner": Self.splTokenProgram,
        "data": ["parsed": [
          "type": "account",
          "info": [
            "mint": Self.solanaAddress,
            "owner": Self.solanaAddress,
            "tokenAmount": ["amount": "2500000", "decimals": 6]
          ]
        ]]
      ]])
    ])
    StubURLProtocol.setHandler(host: host) { body in
      recorder.record(body)
      guard body["method"] as? String == "getAccountInfo" else {
        return RpcStub.error(code: -32601, message: "Method not found")
      }
      return responses.next()
    }
    let provider = try await Self.makeProvider(host: host, source: Self.source())

    let balance = try await provider.getBalance(
      chainId: Self.chainId, token: .contract(address: Self.solanaAddress))
    #expect(balance.rawAmount == 2_500_000)
    #expect(balance.decimals == 6)
    // Read through the Solana account API — no `eth_call`.
    #expect(recorder.methods == ["getAccountInfo", "getAccountInfo"])
    #expect(recorder.firstAddressParam == Self.solanaAddress)
  }

  /// The classic SPL Token program — `SolanaPrograms` is internal to RainCore, so the address is
  /// repeated here rather than imported.
  private static let splTokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"

  /// Hands back queued responses in order, for a flow that calls one method more than once.
  private final class Responder: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data]

    init(queue: [Data]) { self.queue = queue }

    func next() -> Data {
      lock.lock(); defer { lock.unlock() }
      return queue.isEmpty ? queue.last ?? Data() : queue.removeFirst()
    }
  }

  // MARK: - Send

  /// Devnet's CAIP-2 (base58 genesis hash, truncated per the spec).
  private static let devnetCaip2 = "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
  private static let recipient = "11111111111111111111111111111112"

  private static func blockhashHandler(host: String, blockhash: String = solanaAddress) {
    StubURLProtocol.setHandler(host: host) { body in
      body["method"] as? String == "getLatestBlockhash"
        ? RpcStub.rawResult(["context": ["slot": 1], "value": ["blockhash": blockhash]])
        : RpcStub.error(code: -32601, message: "Method not found")
    }
  }

  @Test("sendSolanaNative signs a fresh-blockhash transfer and broadcasts it on the configured cluster")
  func solanaSendNative() async throws {
    let host = "solana-send.rpc"
    Self.blockhashHandler(host: host)
    let account = FakeSolanaAccount(address: Self.solanaAddress, sendResult: .success("SIG-1"))
    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))

    let signature = try await provider.sendSolanaNative(
      chainId: Self.chainId, to: Self.recipient, amount: Decimal(string: "0.5")!)

    #expect(signature == "SIG-1")
    let send = try #require(account.sends.first)
    #expect(account.sends.count == 1)
    #expect(send.caip2 == Self.devnetCaip2)
    #expect(send.rpcUrl == "https://\(host)/") // Privy broadcasts where Rain reads
    // Legacy transaction: compact-u16 signature count, a zero-filled placeholder, then a
    // 150-byte single-transfer message.
    #expect(send.transaction.count == 215)
    #expect(send.transaction.prefix(65) == Data([1] + [UInt8](repeating: 0, count: 64)))
    // Instruction data: u32 LE index 2 (SystemProgram transfer) + u64 LE lamports (0.5 SOL).
    #expect(send.transaction.suffix(12) == Data([2, 0, 0, 0, 0x00, 0x65, 0xCD, 0x1D, 0, 0, 0, 0]))
  }

  @Test("sendSolanaSPLToken composes through core and broadcasts the same bytes")
  func solanaSendSplToken() async throws {
    let host = "solana-send-spl.rpc"
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    // The composer's account reads, in order: mint, recipient wallet, source token account,
    // destination token account.
    let accounts = Responder(queue: [
      RpcStub.rawResult(["context": ["slot": 1], "value": [
        "owner": Self.splTokenProgram,
        "data": ["parsed": ["type": "mint", "info": ["decimals": 6]]]
      ]]),
      RpcStub.rawResult(["context": ["slot": 1], "value": NSNull()]),
      RpcStub.rawResult(["context": ["slot": 1], "value": [
        "owner": Self.splTokenProgram,
        "data": ["parsed": [
          "type": "account",
          "info": [
            "mint": mint,
            "owner": Self.solanaAddress,
            "tokenAmount": ["amount": "5000000", "decimals": 6]
          ]
        ]]
      ]]),
      RpcStub.rawResult(["context": ["slot": 1], "value": NSNull()]) // recipient has no account yet
    ])
    StubURLProtocol.setHandler(host: host) { body in
      switch body["method"] as? String {
      case "getAccountInfo": return accounts.next()
      case "getBalance": return RpcStub.rawResult(["context": ["slot": 1], "value": 1_000_000_000])
      case "getMinimumBalanceForRentExemption": return RpcStub.rawResult(1_488_440)
      case "getLatestBlockhash":
        return RpcStub.rawResult(["context": ["slot": 1], "value": ["blockhash": Self.solanaAddress]])
      case "simulateTransaction":
        return RpcStub.rawResult(["context": ["slot": 1], "value": ["err": NSNull(), "logs": []]])
      default:
        return RpcStub.error(code: -32601, message: "Method not found")
      }
    }
    let account = FakeSolanaAccount(address: Self.solanaAddress, sendResult: .success("SIG-SPL"))
    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))

    let signature = try await provider.sendSolanaSPLToken(
      chainId: Self.chainId, mintAddress: mint, to: Self.recipient, amount: 1.5, decimals: 0)

    #expect(signature == "SIG-SPL")
    let send = try #require(account.sends.first)
    #expect(send.caip2 == Self.devnetCaip2)
    // Two instructions (create the recipient's account, then TransferChecked), so the payload
    // ends with the transfer's tag, u64 LE amount and decimals.
    #expect(send.transaction.suffix(10) == Data([12, 0x60, 0xE3, 0x16, 0, 0, 0, 0, 0, 6]))
  }

  @Test("sendSolanaSPLToken surfaces the composer's preflight errors")
  func solanaSendSplTokenPreflight() async throws {
    let host = "solana-send-spl-preflight.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      // No account at the mint address: nothing to send.
      body["method"] as? String == "getAccountInfo"
        ? RpcStub.rawResult(["context": ["slot": 1], "value": NSNull()])
        : RpcStub.error(code: -32601, message: "Method not found")
    }
    let account = FakeSolanaAccount(address: Self.solanaAddress)
    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))

    await #expect(throws: RainError.tokenNotFound(token: "", chainId: Self.chainId)) {
      _ = try await provider.sendSolanaSPLToken(
        chainId: Self.chainId,
        mintAddress: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        to: Self.recipient,
        amount: 1,
        decimals: 0
      )
    }
    #expect(account.sends.isEmpty)
  }

  @Test("sendSolanaNative surfaces a Privy signing failure")
  func solanaSendFailurePropagates() async throws {
    struct SignerDown: Error {}
    let host = "solana-send-fail.rpc"
    Self.blockhashHandler(host: host)
    let account = FakeSolanaAccount(address: Self.solanaAddress, sendResult: .failure(SignerDown()))
    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))

    await #expect(throws: SignerDown.self) {
      _ = try await provider.sendSolanaNative(
        chainId: Self.chainId, to: Self.recipient, amount: 1)
    }
  }

  @Test("sendSolanaNative rejects an invalid recipient before signing")
  func solanaSendInvalidRecipient() async throws {
    let host = "solana-send-bad-to.rpc"
    Self.blockhashHandler(host: host)
    let account = FakeSolanaAccount(address: Self.solanaAddress)
    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))

    await #expect(throws: RainError.self) {
      _ = try await provider.sendSolanaNative(chainId: Self.chainId, to: "0xNOTBASE58", amount: 1)
    }
    #expect(account.sends.isEmpty)
  }

  @Test("sendSolanaNative on an unconfigured cluster surfaces invalidConfig without signing")
  func solanaSendUnconfiguredCluster() async throws {
    let host = "solana-send-unconfigured.rpc"
    Self.blockhashHandler(host: host)
    let account = FakeSolanaAccount(address: Self.solanaAddress)
    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))

    // Only devnet is registered on this provider.
    await #expect(throws: RainError.invalidConfig(
      details: "No RPC endpoint configured for chainId=\(RainChain.solanaMainnet)"
    )) {
      _ = try await provider.sendSolanaNative(
        chainId: RainChain.solanaMainnet, to: Self.recipient, amount: 1)
    }
    #expect(account.sends.isEmpty)
  }

  @Test("SPL transfers are rejected")
  func solanaSplSendRejected() async throws {
    let provider = try await Self.makeProvider(host: "solana-spl-send.rpc", source: Self.source())

    await #expect(throws: RainError.self) {
      _ = try await provider.sendSolanaSPLToken(
        chainId: Self.chainId,
        mintAddress: Self.solanaAddress,
        to: Self.recipient,
        amount: 1,
        decimals: 6
      )
    }
  }

  // MARK: - History

  @Test("getTransactions on Solana mainnet reads the embedded Solana account's indexer")
  func solanaMainnetHistory() async throws {
    let host = "solana-history.rpc"
    let account = FakeSolanaAccount(address: Self.solanaAddress)
    account.transactionsResults = [
      .success(
        PrivyTransactionsPage(
          transactions: [
            PrivyIndexedTransaction(
              caip2: "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp",
              transactionHash: "SOLSIG1",
              userOperationHash: nil,
              status: "confirmed",
              createdAt: 1_700_000_000_000,
              sponsored: false,
              privyTransactionId: "ptx-1",
              walletId: "w1",
              details: PrivyIndexedTransaction.Details(
                type: "transfer",
                sender: Self.solanaAddress,
                recipient: Self.recipient,
                asset: "sol",
                rawValue: "250000000",
                rawValueDecimals: 9,
                displayValues: [:]
              )
            )
          ],
          nextCursor: nil
        )
      )
    ]

    let provider = try await Self.makeProvider(host: host, source: Self.source(account: account))
    let transactions = try await provider.getTransactions(
      chainId: RainChain.solanaMainnet, limit: nil, offset: nil, order: nil)

    // Reads the Solana account's indexer (native "sol" query only — no registered mints here).
    #expect(account.transactionCalls == ["chain=solana,assets=sol,tokens=nil,limit=10,cursor=nil"])
    let transaction = try #require(transactions.first)
    #expect(transaction.hash == "SOLSIG1")
    #expect(transaction.to == Self.recipient)
    #expect(transaction.value == Decimal(string: "0.25"))
    #expect(transaction.asset == "sol") // named asset, not a mint address
    #expect(transaction.category == .external)
    #expect(transaction.chainId == RainChain.solanaMainnet)
  }

  @Test("getTransactions on a non-mainnet Solana cluster returns empty without hitting the indexer")
  func solanaDevnetHistoryIsEmpty() async throws {
    let account = FakeSolanaAccount(address: Self.solanaAddress)
    let provider = try await Self.makeProvider(host: "solana-history.rpc", source: Self.source(account: account))

    // devnet has no Privy slug, so empty and the indexer is never queried.
    let transactions = try await provider.getTransactions(
      chainId: Self.chainId, limit: nil, offset: nil, order: nil)

    #expect(transactions.isEmpty)
    #expect(account.transactionCalls.isEmpty)
  }

  @Test("write paths reject Solana chain ids up front instead of issuing eth_* calls")
  func solanaWritePathsRejected() async throws {
    let host = "solana-writes.rpc"
    let recorder = Recorder()
    StubURLProtocol.setHandler(host: host) { body in
      recorder.record(body)
      return RpcStub.error(code: -32601, message: "Method not found")
    }
    let provider = try await Self.makeProvider(host: host, source: Self.source())
    let params = WalletTransactionParams(
      from: Self.evmWallet, to: "0xTO", value: "0x1", data: "0x")

    await #expect(throws: RainError.self) {
      _ = try await provider.sendTransaction(chainId: Self.chainId, params: params)
    }
    await #expect(throws: RainError.self) {
      _ = try await provider.estimateTransactionFee(
        chainId: Self.chainId, walletAddress: Self.evmWallet, params: params)
    }
    await #expect(throws: RainError.self) {
      _ = try await provider.signTypedData(
        chainId: Self.chainId, walletAddress: Self.evmWallet, typedData: "{}")
    }
    #expect(recorder.methods.isEmpty) // nothing reached the node
  }
}
