import Testing
import Foundation
import TurnkeySwift
import TurnkeyTypes
import Web3
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// Tests that stub `URLSession.shared` via `MockURLProtocol` run serialized to avoid
/// interfering with each other's stubs (the protocol registration is global).
@Suite("Turnkey Adapter Tests", .serialized)
struct TurnkeyAdapterTests {

  // MARK: - Address resolution

  @Test("getWalletAddress returns address from Turnkey wallet")
  func testGetWalletAddressFromContext() async throws {
    let (manager, _, _) = TestManagers.turnkeyManager()
    let address = try await manager.getWalletAddress()
    #expect(address == MockTurnkey.defaultWalletAddress)
  }

  @Test("getWalletAddress prefers explicit walletAddress override")
  func testGetWalletAddressOverride() async throws {
    let override = "0xover0000000000000000000000000000000000000"
    let (manager, _, _) = TestManagers.turnkeyManager(walletAddress: override)
    let address = try await manager.getWalletAddress()
    #expect(address == override)
  }

  @Test("getWalletAddress refreshes wallets when no eth account is present")
  func testGetWalletAddressRefreshes() async throws {
    let mockTurnkey = MockTurnkey(wallets: [])
    let (manager, turnkey, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.getWalletAddress()
    }
    #expect(turnkey.refreshWalletsCallCount == 1)
  }

  @Test("concurrent first address resolutions share a single wallet refresh")
  func testAddressResolutionSingleFlight() async throws {
    let mockTurnkey = MockTurnkey(wallets: [])
    mockTurnkey.onRefreshWallets = { [weak mockTurnkey] in
      // Simulated Turnkey latency, then the refreshed wallet list appears.
      try await Task.sleep(nanoseconds: 50_000_000)
      mockTurnkey?.wallets = [MockTurnkey.defaultWallet()]
    }
    let (manager, turnkey, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let addresses = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<10 {
        group.addTask { try await manager.getWalletAddress() }
      }
      var results: [String] = []
      for try await address in group { results.append(address) }
      return results
    }

    #expect(addresses.count == 10)
    #expect(Set(addresses) == [MockTurnkey.defaultWalletAddress])
    #expect(turnkey.refreshWalletsCallCount == 1)
  }

  @Test("a failed address resolution is not cached — the next call retries")
  func testFailedAddressResolutionRetries() async throws {
    let mockTurnkey = MockTurnkey(wallets: [])
    let (manager, turnkey, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.getWalletAddress()
    }

    mockTurnkey.wallets = [MockTurnkey.defaultWallet()]
    let address = try await manager.getWalletAddress()

    #expect(address == MockTurnkey.defaultWalletAddress)
    #expect(turnkey.refreshWalletsCallCount == 1)
  }

  @Test("the cached address is dropped when the session organization changes")
  func testAddressCacheEvictedOnSessionChange() async throws {
    let mockTurnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    #expect(try await manager.getWalletAddress() == MockTurnkey.defaultWalletAddress)

    // The host logs out and back in as a different user without rebuilding the SDK.
    let otherAddress = "0x9999999999999999999999999999999999999999"
    mockTurnkey.session = MockTurnkey.defaultSession(organizationId: "other-org-id")
    mockTurnkey.wallets = [MockTurnkey.defaultWallet(address: otherAddress)]

    #expect(try await manager.getWalletAddress() == otherAddress)
  }

  @Test("the cached address survives while the session organization is unchanged")
  func testAddressCacheKeptForSameSession() async throws {
    let mockTurnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    #expect(try await manager.getWalletAddress() == MockTurnkey.defaultWalletAddress)

    // Same session: mutated wallet state must not be re-read — the cache stays authoritative.
    mockTurnkey.wallets = [MockTurnkey.defaultWallet(address: "0x9999999999999999999999999999999999999999")]

    #expect(try await manager.getWalletAddress() == MockTurnkey.defaultWalletAddress)
    #expect(mockTurnkey.refreshWalletsCallCount == 0)
  }

  @Test("a logged-out session cannot keep using the previous user's cached address")
  func testAddressCacheEvictedOnLogout() async throws {
    let mockTurnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    #expect(try await manager.getWalletAddress() == MockTurnkey.defaultWalletAddress)

    mockTurnkey.session = nil
    mockTurnkey.wallets = []

    // The cache is evicted and, with no session left, the re-resolve surfaces the typed
    // re-auth signal rather than a generic wallet-unavailable.
    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.getWalletAddress()
    }
  }

  // MARK: - Balances

  @Test("getAllBalances surfaces a dead session instead of returning an empty list")
  func getAllBalancesSurfacesDeadSession() async throws {
    let mockTurnkey = MockTurnkey(session: nil)
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    // A dead wallet session affects every chain identically; an empty list here would read
    // as zero balances rather than as "re-authenticate".
    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.getAllBalances()
    }
  }

  @Test("getBalance(.native) with Turnkey parses 1 ETH from a single ether balance")
  func testGetNativeBalanceTurnkey() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "1000000000000000000",
        caip19: "eip155:1/slip44:60",
        decimals: 18,
        name: "Ether",
        symbol: "ETH"
      )
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let balance = try await manager.getBalance(chainId: 1, token: .native)

    #expect(balance.token == .native)
    #expect(balance.symbol == "ETH")
    #expect(balance.decimalAmount == 1)
    #expect(client.walletAddressBalanceCalls.count == 1)
    #expect(client.walletAddressBalanceCalls[0].caip2 == "eip155:1")
    #expect(client.walletAddressBalanceCalls[0].address == MockTurnkey.defaultWalletAddress)
  }

  @Test("getBalances with Turnkey returns native plus mapped erc20 balances")
  func testGetERC20BalancesTurnkey() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "1000000",
        caip19: "eip155:1/erc20:\(TestFixtures.usdcAddress)",
        decimals: 6,
        name: "USD Coin",
        symbol: "USDC"
      )
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let balances = try await manager.getTokenBalances(chainId: 1)

    // Native is always included (at zero here — the mock reports no native asset).
    #expect(balances.count == 2)
    #expect(balances.contains { $0.token == .native })
    let usdc = try #require(balances.first { $0.token == .contract(address: TestFixtures.usdcAddress) })
    #expect(usdc.decimals == 6)
    #expect(usdc.symbol == "USDC")
    #expect(usdc.decimalAmount == 1)
    #expect(client.walletAddressBalanceCalls.count == 1)
  }

  @Test("getBalance(.contract) with Turnkey parses eth_call result via the chain reader")
  func testGetERC20BalanceTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_call", result: "0x0F4240") // 1_000_000 (USDC 6dp)

    let (manager, _, _) = TestManagers.turnkeyManager()
    let balance = try await manager.getBalance(
      chainId: 1,
      token: .contract(address: TestFixtures.usdcAddress)
    )

    #expect(balance.decimals == 6)
    #expect(balance.decimalAmount == 1)
    // USDC is in the registry, so no enrichment RPC — only the balanceOf eth_call.
    #expect(MockURLProtocol.recordedMethods == ["eth_call"])
  }

  @Test("getBalance(.contract) with Turnkey maps RPC network failures to networkError")
  func testGetERC20BalanceTurnkeyRpcNetworkError() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stubError(
      method: "eth_call",
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    )

    let (manager, _, _) = TestManagers.turnkeyManager()

    await #expect(throws: RainError.networkError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.getBalance(
        chainId: 1,
        token: .contract(address: TestFixtures.usdcAddress)
      )
    }
  }

  // MARK: - ChainReader routing (Turnkey-unsupported chains)

  /// Returns an adapter wired with a MockChainReader so we can observe routing decisions
  /// without going through `TestManagers.turnkeyManager` (which constructs its own reader).
  private func makeAdapterWithMockChainReader(
    chainIds: [Int],
    walletAddress: String = MockTurnkey.defaultWalletAddress,
    sponsorGas: Bool = false
  ) -> (TurnkeyWalletProviderAdapter, MockTurnkey, MockChainReader) {
    let configs = chainIds.map { NetworkConfig.testConfig(chainId: $0) }
    let mockTurnkey = MockTurnkey()
    let mockReader = MockChainReader()
    let adapter = TurnkeyWalletProviderAdapter(
      turnkey: mockTurnkey,
      networkConfigs: configs,
      walletAddress: walletAddress,
      sponsorGas: sponsorGas,
      chainReader: mockReader,
      history: ThrowingTurnkeyHistory()
    )
    return (adapter, mockTurnkey, mockReader)
  }

  @Test("getBalance(.native) on an unsupported chain routes to the ChainReader")
  func testGetNativeBalanceUnsupportedChainRoutes() async throws {
    let (adapter, mockTurnkey, mockReader) = makeAdapterWithMockChainReader(chainIds: [43114])
    let native = Balance(token: .native, chainId: 43114, rawAmount: BigUInt(7_500_000_000_000_000_000), decimals: 18, symbol: "AVAX")
    mockReader.stubbedSingleBalance = native
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient

    let balance = try await adapter.getBalance(chainId: 43114, token: .native)

    #expect(balance == native)
    #expect(balance.decimalAmount == 7.5)
    #expect(mockReader.getBalanceCalls == [
      MockChainReader.SingleBalanceCall(chainId: 43114, walletAddress: MockTurnkey.defaultWalletAddress, token: .native)
    ])
    // Turnkey's balance API must NOT be hit on an unsupported chain.
    #expect(client.walletAddressBalanceCalls.isEmpty)
  }

  @Test("getBalance(.native) on a supported chain still uses Turnkey's balances API")
  func testGetNativeBalanceSupportedChainUsesTurnkey() async throws {
    let (adapter, mockTurnkey, mockReader) = makeAdapterWithMockChainReader(chainIds: [1])
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "1000000000000000000",
        caip19: "eip155:1/slip44:60",
        decimals: 18,
        name: "Ether",
        symbol: "ETH"
      )
    ]

    let balance = try await adapter.getBalance(chainId: 1, token: .native)

    #expect(balance.token == .native)
    #expect(balance.decimalAmount == 1)
    #expect(client.walletAddressBalanceCalls.count == 1)
    #expect(mockReader.getBalanceCalls.isEmpty)
  }

  @Test("getBalances on an unsupported chain delegates to ChainReader with registry tokens")
  func testGetERC20BalancesUnsupportedChainRoutes() async throws {
    let (adapter, mockTurnkey, mockReader) = makeAdapterWithMockChainReader(chainIds: [43114])
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let avax = Balance(token: .native, chainId: 43114, rawAmount: BigUInt(2_000_000_000_000_000_000), decimals: 18, symbol: "AVAX", name: "Avalanche")
    let usdc = Balance(token: .contract(address: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"), chainId: 43114, rawAmount: BigUInt(42_000_000), decimals: 6, symbol: "USDC") // 42 USDC (6dp)
    let dai = Balance(token: .contract(address: "0xd586E7F844cEa2F87f50152665BCbc2C279D8d70"), chainId: 43114, rawAmount: BigUInt(17) * BigUInt(1_000_000_000_000_000_000), decimals: 18, symbol: "DAI") // 17 DAI (18dp)
    mockReader.stubbedBalances = [avax, usdc, dai]

    let balances = try await adapter.getBalances(chainId: 43114)

    // Native is kept alongside the two non-zero ERC-20s.
    #expect(balances.count == 3)
    #expect(balances.contains { $0.token == .native })
    #expect(balances.contains(usdc))
    #expect(balances.contains(dai))
    #expect(mockReader.balancesCalls.count == 1)
    // Tokens passed to the reader come from TokenRegistry[43114].
    let expectedAddresses = TokenRegistry.tokens(for: 43114).map(\.address)
    #expect(mockReader.balancesCalls[0].tokenAddresses == expectedAddresses)
    #expect(client.walletAddressBalanceCalls.isEmpty)
  }

  @Test("getBalance(.contract) always routes through ChainReader for unified eth_call handling")
  func testGetERC20BalanceAlwaysUsesChainReader() async throws {
    let (adapter, _, mockReader) = makeAdapterWithMockChainReader(chainIds: [1, 43114])
    mockReader.stubbedSingleBalance = Balance(
      token: .contract(address: TestFixtures.usdcAddress),
      chainId: 1,
      rawAmount: BigUInt(9_990_000),
      decimals: 6,
      symbol: "USDC"
    )

    let mainnet = try await adapter.getBalance(chainId: 1, token: .contract(address: TestFixtures.usdcAddress))
    let avax = try await adapter.getBalance(chainId: 43114, token: .contract(address: TestFixtures.usdcAddress))

    #expect(mainnet.decimalAmount == 9.99)
    #expect(avax.decimalAmount == 9.99)
    #expect(mockReader.getBalanceCalls.count == 2)
  }

  // MARK: - getTransactions

  @Test("getTransactions with Turnkey returns mapped activities")
  func testGetTransactionsTurnkey() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.mockTransactionHash = "0x" + String(repeating: "b", count: 64)
    client.mockActivities = [
      MockTurnkey.makeActivity(
        id: "activity-1",
        from: "0xfrom",
        to: "0xto",
        caip2: "eip155:1",
        value: "1000000000000000000",
        data: "0x",
        sendTransactionStatusId: client.mockSendTransactionStatusId
      )
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let list = try await manager.getTransactions(chainId: 1, limit: 10, offset: 0, order: .DESC)

    #expect(list.count == 1)
    #expect(list[0].hash == client.mockTransactionHash)
    #expect(list[0].from == "0xfrom")
    #expect(list[0].to == "0xto")
    #expect(list[0].value == 1.0)
    #expect(list[0].chainId == 1)
    #expect(client.getActivitiesCalls.count == 1)
    #expect(client.sendTransactionStatusCalls.count == 1)
  }

  // MARK: - withdraw signing payload

  @Test("prepareEvmWithdrawal uses Turnkey EIP-712 signing")
  func testBuildTransactionParamForWithdrawAssetTurnkey() async throws {
    let (manager, mockTurnkey, builder) = TestManagers.turnkeyManager()
    builder.mockNonce = BigUInt(42)

    let result = try await manager.prepareEvmWithdrawal(
      chainId: 1,
      assetAddresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: nil
    )

    #expect(result.walletAddress == MockTurnkey.defaultWalletAddress)
    #expect(result.parameters.from == MockTurnkey.defaultWalletAddress)
    #expect(result.parameters.to == TestFixtures.contractAddress)
    #expect(result.parameters.data.hasPrefix("0x"))
    #expect(mockTurnkey.signRawPayloadCalls.count == 1)

    let signCall = try #require(mockTurnkey.signRawPayloadCalls.first)
    #expect(signCall.signWith == MockTurnkey.defaultWalletAddress)
    #expect(signCall.encoding == .payload_encoding_eip712)
    #expect(signCall.hashFunction == .hash_function_no_op)
    #expect(!signCall.payload.isEmpty)
  }

  // MARK: - signRawPayload failure propagation

  @Test("withdrawCollateral propagates Turnkey sign error")
  func testTurnkeySignFailurePropagates() async throws {
    let mockTurnkey = MockTurnkey()
    mockTurnkey.signRawPayloadError = NSError(
      domain: "Turnkey",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "sign failed"]
    )
    let (manager, _, builder) = TestManagers.turnkeyManager(turnkey: mockTurnkey)
    builder.mockNonce = BigUInt(1)

    do {
      _ = try await manager.prepareEvmWithdrawal(
        chainId: 1,
        assetAddresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature(),
        nonce: BigUInt(1)
      )
      Issue.record("Expected Turnkey sign error to propagate")
    } catch let error as NSError {
      #expect(error.domain == "Turnkey")
      #expect(error.code == 42)
    } catch {
      Issue.record("Expected NSError from Turnkey sign error, got \(type(of: error))")
    }
  }

  // MARK: - sendNative / sendToken via Turnkey (URLSession-stubbed)

  @Test("sendNative with Turnkey returns mock tx hash")
  func testSendNativeTokenTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let expectedHash = "0x" + String(repeating: "f", count: 64)
    client.sendTransactionStatusQueue = [.broadcasted(hash: expectedHash)]

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let result = try await manager.sendNative(
      chainId: 1,
      to: TestFixtures.recipientAddress,
      amount: 1.5
    )

    #expect(result.transactionHash == expectedHash)
    #expect(client.ethSendTransactionCalls.count == 1)
    // The recipient is validated and broadcast in its EIP-55 checksummed form.
    #expect(client.ethSendTransactionCalls[0].to
      == (try RainWithdrawAddresses.checksummed(TestFixtures.recipientAddress, label: "to")))
    #expect(client.sendTransactionStatusCalls.count == 1)
  }

  @Test("sendNative rejects a malformed recipient before touching the network")
  func testSendNativeInvalidRecipientThrows() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.invalidRecipient(address: "", reason: "")) {
      _ = try await manager.sendNative(chainId: 1, to: "0x1234", amount: 1.0)
    }
    #expect(client.ethSendTransactionCalls.isEmpty)
  }

  @Test("sendToken rejects a malformed recipient before touching the network")
  func testSendTokenInvalidRecipientThrows() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.invalidRecipient(address: "", reason: "")) {
      _ = try await manager.sendToken(
        chainId: 1,
        contractAddress: TestFixtures.tokenAddress,
        to: "not-an-address",
        amount: 100.0,
        decimals: 6
      )
    }
    #expect(client.ethSendTransactionCalls.isEmpty)
  }

  @Test("a status-poll timeout surfaces transactionPending with the status id, not a failure")
  func testSendTransactionPollTimeoutThrowsTransactionPending() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    // Turnkey accepted the submission but never surfaces a hash within the polling window.
    client.sendTransactionStatusQueue = [.pending()]

    let adapter = TurnkeyWalletProviderAdapter(
      turnkey: mockTurnkey,
      networkConfigs: TestFixtures.configs(),
      sponsorGas: false,
      chainReader: MockChainReader()
    )
    adapter.pollingIntervalNanoseconds = 1

    do {
      _ = try await adapter.sendTransaction(
        chainId: 1,
        params: WalletTransactionParams(
          from: MockTurnkey.defaultWalletAddress,
          to: TestFixtures.recipientAddress,
          value: "0x1",
          data: "0x"
        )
      )
      Issue.record("Expected transactionPending after poll timeout")
    } catch let error as RainError {
      guard case .transactionPending(let statusId) = error else {
        Issue.record("Expected transactionPending, got \(error)")
        return
      }
      #expect(statusId == "send-status-id")
    }
    // The transaction WAS handed to Turnkey; the timeout must not look like a pre-broadcast error.
    #expect(client.ethSendTransactionCalls.count == 1)
    #expect(client.sendTransactionStatusCalls.count == 30)
  }

  @Test("sendToken with Turnkey returns mock tx hash and routes to contract address")
  func testSendERC20TokenTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let expectedHash = "0x" + String(repeating: "e", count: 64)
    client.sendTransactionStatusQueue = [.broadcasted(hash: expectedHash)]

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let result = try await manager.sendToken(
      chainId: 1,
      contractAddress: TestFixtures.tokenAddress,
      to: TestFixtures.recipientAddress,
      amount: 100.0,
      decimals: 6
    )

    #expect(result.transactionHash == expectedHash)
    #expect(client.ethSendTransactionCalls.count == 1)
    // ERC-20 transfers target the token contract; recipient is encoded in calldata.
    #expect(client.ethSendTransactionCalls[0].to == TestFixtures.tokenAddress)
  }

  @Test("approveTokenAllowance with Turnkey broadcasts arbitrary ERC-20 approve calldata")
  func testApproveTokenAllowanceTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let expectedHash = "0x" + String(repeating: "c", count: 64)
    client.sendTransactionStatusQueue = [.broadcasted(hash: expectedHash)]

    // Broadcast routing, not the trusted-target guard: trust the arbitrary token this test sends
    // so the assertion is about what reached Turnkey.
    // The default fixture RPC URL's host is the one MockURLProtocol intercepts — a live RPC URL
    // here would send the adapter's eth_* calls to the real network (flaky/timeouts on CI).
    let (manager, _, builder) = TestManagers.turnkeyManager(
      turnkey: mockTurnkey,
      configs: TestFixtures.configs(chainId: RainChain.baseSepolia),
      authPullChainIds: [RainChain.baseSepolia],
      authPullTokenAddresses: [RainChain.baseSepolia: TestFixtures.tokenAddress]
    )
    builder.stubbedApproveData = "0x095ea7b3deadbeef"

    let result = try await manager.approveTokenAllowance(
      chainId: RainChain.baseSepolia,
      contractAddress: TestFixtures.tokenAddress,
      spender: TestFixtures.authPullOperator
    )

    #expect(result.transactionHash == expectedHash)
    #expect(client.ethSendTransactionCalls.count == 1)
    // The approval targets the token contract; the spender is encoded in the calldata.
    #expect(client.ethSendTransactionCalls[0].to == TestFixtures.tokenAddress)
    #expect(builder.approveCalls[0].amount == RainTokenAllowance.unlimitedRawAmount)
  }

  @Test("sendNative with Turnkey reports an unclassifiable send failure as an unknown outcome")
  func testSendNativeTokenTurnkeyEthSendError() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = NSError(
      domain: "Turnkey",
      code: 500,
      userInfo: [NSLocalizedDescriptionKey: "send failed"]
    )

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    // The vendor polls inside the send call, so a failure it cannot name may follow an accepted
    // submit: RAIN_305, never a settled providerError that would invite a second send.
    await #expect(throws: RainError.transactionOutcomeUnknown(details: "")) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
    #expect(client.ethSendTransactionCalls.count == 1)
  }

  // MARK: - Polling status

  @Test("pollForTransactionHash throws when status reports failure")
  func testPollForTransactionHashFailureStatus() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.failed(message: "reverted")]

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  @Test("a zero gas estimate on a plain transfer falls back to 21000 rather than submitting gasLimit 0")
  func testZeroGasEstimateFallsBackToDefault() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_getTransactionCount", result: "0x1")
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x0")
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800")

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0x" + String(repeating: "8", count: 64))]

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    _ = try await manager.sendNative(
      chainId: 1,
      to: TestFixtures.recipientAddress,
      amount: 1.0
    )

    let body = try #require(client.ethSendTransactionCalls.first)
    // 21000 fallback, then the same +20% buffer every estimate gets.
    #expect(body.gasLimit == "25200")
  }

  @Test("a zero gas estimate on a contract call fails loudly instead of sending 21000")
  func testZeroGasEstimateWithCalldataThrows() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_getTransactionCount", result: "0x1")
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x0")
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800")

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    // An ERC-20 transfer carries calldata, so 21000 would run out of gas on-chain and burn the fee.
    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.sendToken(
        chainId: 1,
        contractAddress: TestFixtures.tokenAddress,
        to: TestFixtures.recipientAddress,
        amount: 100.0,
        decimals: 6
      )
    }
    // The underestimated transaction must never reach Turnkey.
    #expect(client.ethSendTransactionCalls.isEmpty)
  }

  @Test("pollForTransactionHash keeps polling until status returns a hash")
  func testPollForTransactionHashRetriesUntilSuccess() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let expectedHash = "0x" + String(repeating: "9", count: 64)
    client.sendTransactionStatusQueue = [
      .pending(),
      .broadcasted(hash: expectedHash)
    ]

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    let result = try await manager.sendNative(
      chainId: 1,
      to: TestFixtures.recipientAddress,
      amount: 1.0
    )

    #expect(result.transactionHash == expectedHash)
    #expect(client.sendTransactionStatusCalls.count == 2)
  }

  // MARK: - withdrawCollateral with Turnkey (URLSession-stubbed)

  @Test("withdrawCollateral with Turnkey returns hash and signs typed data once")
  func testWithdrawCollateralTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    stubSendTransactionRPCs()

    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let expectedHash = "0x" + String(repeating: "7", count: 64)
    client.sendTransactionStatusQueue = [.broadcasted(hash: expectedHash)]

    let (manager, _, builder) = TestManagers.turnkeyManager(turnkey: mockTurnkey)
    builder.mockNonce = BigUInt(42)

    let txHash = try await manager.withdrawCollateral(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature(),
      nonce: nil
    )

    #expect(txHash == expectedHash)
    #expect(mockTurnkey.signRawPayloadCalls.count == 1)
    #expect(client.ethSendTransactionCalls.count == 1)
    #expect(client.ethSendTransactionCalls[0].to == TestFixtures.contractAddress)
  }

  // MARK: - estimateWithdrawalFee with Turnkey

  @Test("estimateWithdrawalFee with Turnkey computes gas × price")
  func testEstimateWithdrawalFeeTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208") // 21000
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800") // 20 gwei = 20_000_000_000

    let (manager, _, builder) = TestManagers.turnkeyManager()
    builder.mockNonce = BigUInt(1)

    let fee = try await manager.estimateWithdrawalFee(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature()
    )

    // 21_000 gas × 20 gwei = 420_000_000_000_000 wei = exactly 0.00042 native units.
    #expect(fee == Decimal(string: "0.00042"))
  }

  @Test("estimateWithdrawalFee with Turnkey maps RPC network failures to networkError")
  func testEstimateWithdrawalFeeTurnkeyRpcNetworkError() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stubError(
      method: "eth_estimateGas",
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    )

    let (manager, _, builder) = TestManagers.turnkeyManager()
    builder.mockNonce = BigUInt(1)

    await #expect(throws: RainError.networkError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.estimateWithdrawalFee(
        chainId: 1,
        addresses: TestFixtures.defaultWithdrawAddresses,
        amount: 100.0,
        decimals: 18,
        adminSignature: TestFixtures.adminSignature()
      )
    }
  }

  @Test("estimateWithdrawalFee(prepared:) estimates on the prepared calldata without another signature")
  func testEstimateWithdrawalFeePreparedSignsNothing() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208") // 21000
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800") // 20 gwei

    let (manager, turnkey, builder) = TestManagers.turnkeyManager()
    builder.mockNonce = BigUInt(1)

    let prepared = try await manager.prepareWithdrawal(
      chainId: 1,
      addresses: TestFixtures.defaultWithdrawAddresses,
      amount: 100.0,
      decimals: 18,
      adminSignature: TestFixtures.adminSignature()
    )
    let signaturesAfterPrepare = turnkey.signRawPayloadCalls.count

    let fee = try await manager.estimateWithdrawalFee(chainId: 1, prepared: prepared)

    #expect(fee == Decimal(string: "0.00042"))
    // The quote must reuse the preparation's signed calldata, never mint a second authorization.
    #expect(turnkey.signRawPayloadCalls.count == signaturesAfterPrepare)
  }

  @Test("estimateWithdrawalFee(prepared:) rejects a Solana preparation")
  func testEstimateWithdrawalFeePreparedRejectsSolana() async throws {
    let (manager, _, _) = TestManagers.turnkeyManager()
    let prepared = RainPreparedWithdrawal.solana(
      UnsignedSolanaTransfer(transaction: [1, 2, 3], recentBlockhash: "hash")
    )

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.estimateWithdrawalFee(chainId: SolanaChains.mainnet, prepared: prepared)
    }
  }

  // MARK: - estimateGas with Turnkey

  @Test("estimateGas with Turnkey computes gas × price for arbitrary calldata")
  func testEstimateGasTurnkey() async throws {
    await MockURLProtocol.install()
    defer { MockURLProtocol.reset() }
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208") // 21000
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800") // 20 gwei

    let (manager, _, _) = TestManagers.turnkeyManager()

    let fee = try await manager.estimateGas(
      chainId: 1,
      from: TestFixtures.walletAddress,
      to: TestFixtures.contractAddress,
      data: "0xdeadbeef"
    )

    // 21_000 gas × 20 gwei = 420_000_000_000_000 wei = exactly 0.00042 native units.
    #expect(fee == Decimal(string: "0.00042"))
  }

  @Test("estimateGas throws internalError when the provider cannot estimate fees")
  func testEstimateGasUnsupportedProvider() async throws {
    let (manager, _) = try await TestManagers.stubProviderManager()

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await manager.estimateGas(
        chainId: 1,
        from: TestFixtures.walletAddress,
        to: TestFixtures.contractAddress,
        data: "0x"
      )
    }
  }

  // MARK: - getTransactions error path

  @Test("getTransactions with Turnkey propagates getActivities error")
  func testGetTransactionsTurnkeyError() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.getActivitiesError = NSError(
      domain: "Turnkey",
      code: 503,
      userInfo: [NSLocalizedDescriptionKey: "service unavailable"]
    )

    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.providerError(underlying: NSError(domain: "x", code: 0))) {
      _ = try await manager.getTransactions(chainId: 1)
    }
  }

  // MARK: - Session resolution

  @Test("sendNative with Turnkey throws when session is missing")
  func testTurnkeyNoSession() async throws {
    let mockTurnkey = MockTurnkey(session: nil)
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  @Test("sendNative with Turnkey throws when client is missing")
  func testTurnkeyNoClient() async throws {
    let mockTurnkey = MockTurnkey(client: nil)
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: mockTurnkey)

    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.sendNative(
        chainId: 1,
        to: TestFixtures.recipientAddress,
        amount: 1.0
      )
    }
  }

  // MARK: - Helpers

  /// Stubs the three JSON-RPC calls made when building a Turnkey send-transaction body.
  private func stubSendTransactionRPCs() {
    MockURLProtocol.stub(method: "eth_getTransactionCount", result: "0x1")
    MockURLProtocol.stub(method: "eth_estimateGas", result: "0x5208")  // 21000
    MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800") // 20 gwei
  }
}
