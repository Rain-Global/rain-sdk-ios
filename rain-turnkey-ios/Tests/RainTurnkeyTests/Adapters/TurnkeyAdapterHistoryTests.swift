import Testing
import Foundation
import TurnkeySwift
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// Tests the adapter's indexed-history path: mapping of Turnkey's history rows onto
/// `RainTransaction`, request parameters, ordering/slicing, and the activity-log fallback.
@Suite("Turnkey Adapter History Tests")
struct TurnkeyAdapterHistoryTests {

  private func makeAdapter(
    turnkey: MockTurnkey = MockTurnkey(),
    history: TurnkeyHistoryProviding = MockTurnkeyHistory(),
    configs: [NetworkConfig] = TestFixtures.configs()
  ) -> TurnkeyWalletProviderAdapter {
    TurnkeyWalletProviderAdapter(
      turnkey: turnkey,
      networkConfigs: configs,
      sponsorGas: false,
      chainReader: MockChainReader(),
      history: history
    )
  }

  private func ethTransaction(
    hash: String = "0xhash",
    timestamp: String = "2026-08-12T10:00:00Z",
    blockNumber: String = "123",
    status: String? = "CONFIRMED",
    from: String? = "0xsender",
    to: String? = "0xrecipient",
    transfers: [TurnkeyHistoryTransfer] = [],
    sponsored: Bool? = false
  ) -> TurnkeyEthHistoryTransaction {
    TurnkeyEthHistoryTransaction(
      transactionHash: hash,
      block: TurnkeyHistoryBlock(number: blockNumber, hash: "0xblock", timestamp: timestamp),
      status: status,
      from: from,
      to: to,
      transfers: transfers,
      turnkey: sponsored.map { TurnkeyHistoryOrigin(sponsored: $0) }
    )
  }

  private func nativeOut(
    amount: String = "1500000000000000000",
    counterparty: String = "0xrecipient"
  ) -> TurnkeyHistoryTransfer {
    TurnkeyHistoryTransfer(
      direction: "OUT",
      asset: TurnkeyHistoryAsset(
        caip19: "eip155:1/slip44:60",
        symbol: "ETH",
        name: "Ether",
        decimals: 18
      ),
      amount: amount,
      counterparty: counterparty,
      display: TurnkeyHistoryDisplay(crypto: "1.5", usd: "5000.00")
    )
  }

  // MARK: - EVM mapping

  @Test("evm native OUT transfer maps hash, block, value and counterparty")
  func evmNativeOutMapping() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [ethTransaction(transfers: [nativeOut()])]
    )
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.hash == "0xhash")
    #expect(tx.uniqueId == "0xhash")
    #expect(tx.blockNumber == "123")
    #expect(tx.timestamp == "2026-08-12T10:00:00Z")
    // OUT is relative to the queried wallet, so the wallet is the sender.
    #expect(tx.from == MockTurnkey.defaultWalletAddress)
    #expect(tx.to == "0xrecipient")
    #expect(tx.value == Decimal(string: "1.5"))
    #expect(tx.rawValue == "1500000000000000000")
    #expect(tx.decimals == 18)
    #expect(tx.asset == "ETH")
    #expect(tx.tokenAddress == nil)
    #expect(tx.category == .external)
    #expect(tx.chainId == 1)
    #expect(tx.metadata?.caip2 == "eip155:1")
    #expect(tx.metadata?.status == "confirmed")
    #expect(tx.metadata?.sponsored == false)
    #expect(tx.metadata?.type == "transferSent")
    #expect(tx.metadata?.displayValues == ["crypto": "1.5", "usd": "5000.00"])
  }

  @Test("evm IN transfer swaps counterparty into from and wallet into to")
  func evmIncomingMapping() async throws {
    let incoming = TurnkeyHistoryTransfer(
      direction: "IN",
      asset: TurnkeyHistoryAsset(caip19: "eip155:1/slip44:60", symbol: "ETH", decimals: 18),
      amount: "1000000000000000000",
      counterparty: "0xpayer"
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [ethTransaction(from: "0xpayer", to: nil, transfers: [incoming])]
    )
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.from == "0xpayer")
    #expect(tx.to == MockTurnkey.defaultWalletAddress)
    #expect(tx.metadata?.type == "transferReceived")
  }

  @Test("evm erc20 transfer carries token address and erc20 category")
  func evmErc20Mapping() async throws {
    let tokenOut = TurnkeyHistoryTransfer(
      direction: "OUT",
      asset: TurnkeyHistoryAsset(
        caip19: "eip155:1/erc20:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        symbol: "USDC",
        decimals: 6
      ),
      amount: "2500000",
      counterparty: "0xrecipient"
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [ethTransaction(transfers: [tokenOut])]
    )
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.tokenAddress == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
    #expect(tx.category == .erc20)
    #expect(tx.value == Decimal(string: "2.5"))
    #expect(tx.asset == "USDC")
  }

  @Test("evm row without transfers keeps transaction addresses and carries no amount")
  func evmNoTransfersMapping() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [ethTransaction()])
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.from == "0xsender")
    #expect(tx.to == "0xrecipient")
    #expect(tx.value == nil)
    #expect(tx.rawValue == nil)
    #expect(tx.category == .external)
    #expect(tx.metadata?.type == nil)
  }

  @Test("evm large amount scales exactly")
  func evmLargeAmountExact() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [ethTransaction(transfers: [nativeOut(amount: "123456789012345678901")])]
    )
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.value == Decimal(string: "123.456789012345678901"))
  }

  // MARK: - Request parameters

  @Test("evm history request carries session, wallet, caip2 and clamped limit")
  func evmRequestParameters() async throws {
    let history = MockTurnkeyHistory()
    let adapter = makeAdapter(history: history)

    _ = try await adapter.getTransactions(chainId: 1, limit: 7, offset: 5, order: nil)

    let call = try #require(history.ethCalls.first)
    #expect(call.organizationId == "org-id")
    #expect(call.sessionPublicKey == "pubkey")
    #expect(call.address == MockTurnkey.defaultWalletAddress)
    #expect(call.caip2 == "eip155:1")
    #expect(call.limit == 12)
  }

  @Test("history limit defaults to 10 and caps at 100")
  func historyLimitClamping() async throws {
    let history = MockTurnkeyHistory()
    let adapter = makeAdapter(history: history)

    _ = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil)
    _ = try await adapter.getTransactions(chainId: 1, limit: 90, offset: 40, order: nil)

    #expect(history.ethCalls.count == 2)
    #expect(history.ethCalls[0].limit == 10)
    #expect(history.ethCalls[1].limit == 100)
  }

  // MARK: - Ordering and slicing

  @Test("rows sort DESC by default and honor ASC, offset and limit")
  func orderingAndSlicing() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [
        ethTransaction(hash: "0xnewest", timestamp: "2026-08-12T12:00:00Z"),
        ethTransaction(hash: "0xoldest", timestamp: "2026-08-12T10:00:00Z"),
        ethTransaction(hash: "0xmiddle", timestamp: "2026-08-12T11:00:00Z"),
      ]
    )
    let adapter = makeAdapter(history: history)

    let desc = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil)
    #expect(desc.map(\.hash) == ["0xnewest", "0xmiddle", "0xoldest"])

    let asc = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: .ASC)
    #expect(asc.map(\.hash) == ["0xoldest", "0xmiddle", "0xnewest"])

    let sliced = try await adapter.getTransactions(chainId: 1, limit: 1, offset: 1, order: .DESC)
    #expect(sliced.map(\.hash) == ["0xmiddle"])
  }

  @Test("timestamps with explicit zone offsets parse for sorting")
  func offsetTimestampsSort() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [
        ethTransaction(hash: "0xolder", timestamp: "2026-08-12T10:00:00+00:00"),
        ethTransaction(hash: "0xnewer", timestamp: "2026-08-12T11:00:00+00:00"),
      ]
    )
    let adapter = makeAdapter(history: history)

    let desc = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil)
    #expect(desc.map(\.hash) == ["0xnewer", "0xolder"])
  }

  // MARK: - Solana

  @Test("solana history maps signature, native SOL and SPL rows")
  func solanaMapping() async throws {
    let wallet = MockTurnkey.defaultSolanaAddress
    let devnetCaip2 = "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
    let recipient = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let history = MockTurnkeyHistory()
    history.solResponse = TurnkeySolHistoryResponse(
      transactions: [
        TurnkeySolHistoryTransaction(
          signature: "5solSig",
          block: TurnkeyHistoryBlock(number: "9", hash: "bh", timestamp: "2026-08-12T11:00:00Z"),
          status: "FINALIZED",
          feePayer: wallet,
          transfers: [
            TurnkeyHistoryTransfer(
              direction: "OUT",
              asset: TurnkeyHistoryAsset(
                caip19: "\(devnetCaip2)/slip44:501",
                symbol: "SOL",
                decimals: 9
              ),
              amount: "1000000000",
              counterparty: recipient
            )
          ],
          turnkey: TurnkeyHistoryOrigin(sponsored: false)
        ),
        TurnkeySolHistoryTransaction(
          signature: "5splSig",
          block: TurnkeyHistoryBlock(number: "8", hash: "bh", timestamp: "2026-08-12T10:00:00Z"),
          status: "CONFIRMED",
          feePayer: wallet,
          transfers: [
            TurnkeyHistoryTransfer(
              direction: "IN",
              asset: TurnkeyHistoryAsset(
                caip19: "\(devnetCaip2)/token:MintAddr111",
                symbol: "USDC",
                decimals: 6
              ),
              amount: "2500000",
              counterparty: recipient
            )
          ]
        ),
      ]
    )
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
    let adapter = makeAdapter(
      turnkey: turnkey,
      history: history,
      configs: [.testConfig(chainId: SolanaChains.devnet)]
    )

    let txs = try await adapter.getTransactions(
      chainId: SolanaChains.devnet, limit: nil, offset: nil, order: nil
    )

    let call = try #require(history.solCalls.first)
    #expect(call.address == wallet)
    #expect(call.caip2 == devnetCaip2)
    #expect(history.ethCalls.isEmpty)

    let native = try #require(txs.first)
    #expect(native.hash == "5solSig")
    #expect(native.from == wallet)
    #expect(native.to == recipient)
    #expect(native.value == Decimal(1))
    #expect(native.asset == "SOL")
    #expect(native.tokenAddress == nil)
    #expect(native.category == .external)
    #expect(native.metadata?.status == "finalized")

    let spl = try #require(txs.last)
    #expect(spl.hash == "5splSig")
    #expect(spl.from == recipient)
    #expect(spl.to == wallet)
    #expect(spl.tokenAddress == "MintAddr111")
    #expect(spl.category == .token)
    #expect(spl.value == Decimal(string: "2.5"))
    #expect(spl.metadata?.type == "transferReceived")
  }

  @Test("erc721 transfer maps the collection address and erc721 category")
  func erc721Mapping() async throws {
    let nftIn = TurnkeyHistoryTransfer(
      direction: "IN",
      asset: TurnkeyHistoryAsset(caip19: "eip155:1/erc721:0xNftContract/1234", symbol: "COOL"),
      amount: "1",
      counterparty: "0xminter"
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [ethTransaction(transfers: [nftIn])])
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.tokenAddress == "0xNftContract")
    #expect(tx.category == .erc721)
  }

  @Test("amount without decimals keeps value nil and rawValue set")
  func amountWithoutDecimals() async throws {
    let unknownScale = TurnkeyHistoryTransfer(
      direction: "OUT",
      asset: TurnkeyHistoryAsset(caip19: "eip155:1/erc20:0xtoken", symbol: "MYS"),
      amount: "12345",
      counterparty: "0xrecipient"
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [ethTransaction(transfers: [unknownScale])])
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.value == nil)
    #expect(tx.rawValue == "12345")
  }

  @Test("non-numeric amount reports nil value, not a fabricated zero")
  func nonNumericAmount() async throws {
    let garbage = TurnkeyHistoryTransfer(
      direction: "OUT",
      asset: TurnkeyHistoryAsset(caip19: "eip155:1/erc20:0xtoken", symbol: "MYS", decimals: 6),
      amount: "not-a-number",
      counterparty: "0xrecipient"
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [ethTransaction(transfers: [garbage])])
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.value == nil)
    #expect(tx.rawValue == "not-a-number")
  }

  @Test("multi-transfer row renders its first transfer only")
  func multiTransferFirstOnly() async throws {
    let swap = ethTransaction(
      transfers: [
        nativeOut(amount: "1000000000000000000"),
        TurnkeyHistoryTransfer(
          direction: "IN",
          asset: TurnkeyHistoryAsset(caip19: "eip155:1/erc20:0xweth", symbol: "WETH", decimals: 18),
          amount: "300000000000000000",
          counterparty: "0xpool"
        ),
      ]
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [swap])
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.asset == "ETH")
    #expect(tx.metadata?.type == "transferSent")
  }

  @Test("multi-word status maps to the privy-style camelCase vocabulary")
  func camelCaseStatus() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [ethTransaction(status: "EXECUTION_REVERTED")]
    )
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.metadata?.status == "executionReverted")
  }

  @Test("fractional timestamp is normalized to second-precision Zulu")
  func fractionalTimestampNormalized() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [ethTransaction(timestamp: "2026-08-12T10:00:00.123Z")]
    )
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.timestamp == "2026-08-12T10:00:00Z")
  }

  @Test("row without a block sorts newest so a pending send stays on the first page")
  func pendingRowSortsNewest() async throws {
    let pending = TurnkeyEthHistoryTransaction(
      transactionHash: "0xpending",
      block: nil,
      status: nil,
      from: "0xsender",
      to: nil,
      transfers: [],
      turnkey: nil
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [
        ethTransaction(hash: "0xmined", timestamp: "2026-08-12T12:00:00Z"),
        pending,
      ]
    )
    let adapter = makeAdapter(history: history)

    let firstPage = try await adapter.getTransactions(chainId: 1, limit: 1, offset: nil, order: nil)

    #expect(firstPage.map(\.hash) == ["0xpending"])
    #expect(firstPage.first?.timestamp == nil)
  }

  @Test("rows sharing a timestamp keep API order under DESC and reverse under ASC")
  func tieBreakOrdering() async throws {
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(
      transactions: [
        ethTransaction(hash: "0xfirstListed", timestamp: "2026-08-12T10:00:00Z"),
        ethTransaction(hash: "0xsecondListed", timestamp: "2026-08-12T10:00:00Z"),
      ]
    )
    let adapter = makeAdapter(history: history)

    let desc = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: .DESC)
    #expect(desc.map(\.hash) == ["0xfirstListed", "0xsecondListed"])

    let asc = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: .ASC)
    #expect(asc.map(\.hash) == ["0xsecondListed", "0xfirstListed"])
  }

  @Test("sponsored solana OUT reports the wallet as sender, not the fee payer")
  func sponsoredSolanaOut() async throws {
    let wallet = MockTurnkey.defaultSolanaAddress
    let devnetCaip2 = "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
    let recipient = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let history = MockTurnkeyHistory()
    history.solResponse = TurnkeySolHistoryResponse(
      transactions: [
        TurnkeySolHistoryTransaction(
          signature: "sponsoredSig",
          block: TurnkeyHistoryBlock(number: nil, hash: nil, timestamp: "2026-08-13T18:31:47Z"),
          status: "FINALIZED",
          feePayer: "SponsorFeePayer111",
          transfers: [
            TurnkeyHistoryTransfer(
              direction: "OUT",
              asset: TurnkeyHistoryAsset(caip19: "\(devnetCaip2)/slip44:501", symbol: "SOL", decimals: 9),
              amount: "1000000000",
              counterparty: recipient
            )
          ],
          turnkey: TurnkeyHistoryOrigin(sponsored: true)
        )
      ]
    )
    let adapter = makeAdapter(
      turnkey: MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()]),
      history: history,
      configs: [.testConfig(chainId: SolanaChains.devnet)]
    )

    let tx = try #require(
      try await adapter.getTransactions(
        chainId: SolanaChains.devnet, limit: nil, offset: nil, order: nil
      ).first
    )

    #expect(tx.from == wallet)
    #expect(tx.to == recipient)
    #expect(tx.metadata?.sponsored == true)
  }

  @Test("hostile payload shapes render defensively instead of crashing or scaling absurdly")
  func hostilePayloadShapes() async throws {
    let hostile = TurnkeyHistoryTransfer(
      direction: "OUT",
      // Malformed CAIP-19: empty reference before a trailing slash.
      asset: TurnkeyHistoryAsset(caip19: "eip155:1/erc20:/", symbol: "EVIL", decimals: 999_999_999),
      amount: "12345",
      counterparty: "0xrecipient"
    )
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [ethTransaction(transfers: [hostile])])
    let adapter = makeAdapter(history: history)

    let tx = try #require(
      try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil).first
    )

    #expect(tx.tokenAddress == nil)
    #expect(tx.category == .external)
    #expect(tx.value == nil)
    #expect(tx.decimals == nil)
    #expect(tx.rawValue == "12345")
  }

  @Test("blank counterparty falls back to transaction addresses instead of empty strings")
  func blankCounterpartyHandling() async throws {
    let wallet = MockTurnkey.defaultSolanaAddress
    let devnetCaip2 = "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
    // Live shape: Turnkey sends counterparty as "" (not null) when it is unknown.
    func transfer(_ direction: String) -> TurnkeyHistoryTransfer {
      TurnkeyHistoryTransfer(
        direction: direction,
        asset: TurnkeyHistoryAsset(caip19: "\(devnetCaip2)/token:Mint111", symbol: "USDC", decimals: 6),
        amount: "1000000",
        counterparty: ""
      )
    }
    let history = MockTurnkeyHistory()
    history.solResponse = TurnkeySolHistoryResponse(
      transactions: [
        TurnkeySolHistoryTransaction(
          signature: "inSig",
          block: TurnkeyHistoryBlock(number: nil, hash: nil, timestamp: "2026-08-13T18:31:47Z"),
          feePayer: wallet,
          transfers: [transfer("IN")]
        ),
        TurnkeySolHistoryTransaction(
          signature: "outSig",
          block: TurnkeyHistoryBlock(number: nil, hash: nil, timestamp: "2026-08-13T18:14:24Z"),
          feePayer: wallet,
          transfers: [transfer("OUT")]
        ),
      ]
    )
    let adapter = makeAdapter(
      turnkey: MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()]),
      history: history,
      configs: [.testConfig(chainId: SolanaChains.devnet)]
    )

    let txs = try await adapter.getTransactions(
      chainId: SolanaChains.devnet, limit: nil, offset: nil, order: nil
    )

    let incoming = try #require(txs.first { $0.hash == "inSig" })
    #expect(incoming.from == wallet)
    #expect(incoming.to == wallet)
    let outgoing = try #require(txs.first { $0.hash == "outSig" })
    #expect(outgoing.from == wallet)
    #expect(outgoing.to == nil)
  }

  // MARK: - Fallback

  @Test("history failure falls back to the activity log")
  func fallbackToActivities() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    client.mockActivities = [
      MockTurnkey.makeActivity(
        id: "activity-1",
        from: MockTurnkey.defaultWalletAddress,
        to: "0xrecipient",
        caip2: "eip155:1",
        value: "1000000000000000000",
        data: "0x",
        sendTransactionStatusId: client.mockSendTransactionStatusId
      )
    ]
    let history = MockTurnkeyHistory()
    history.error = TurnkeyHistoryError(statusCode: 403, body: "feature is not enabled")
    let adapter = makeAdapter(turnkey: mockTurnkey, history: history)

    let txs = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil)

    #expect(history.ethCalls.count == 1)
    #expect(client.getActivitiesCalls.count == 1)
    #expect(txs.count == 1)
    #expect(txs.first?.uniqueId == "activity-1")
    #expect(txs.first?.value == Decimal(1))
  }

  @Test("history success does not touch the activity log")
  func noFallbackOnSuccess() async throws {
    let mockTurnkey = MockTurnkey()
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let history = MockTurnkeyHistory()
    history.ethResponse = TurnkeyEthHistoryResponse(transactions: [ethTransaction()])
    let adapter = makeAdapter(turnkey: mockTurnkey, history: history)

    _ = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil)

    #expect(client.getActivitiesCalls.isEmpty)
  }

  @Test("missing session throws tokenExpired without consulting the activity log")
  func missingSessionThrows() async throws {
    let mockTurnkey = MockTurnkey(session: nil)
    let client = mockTurnkey.turnkeyClient as! MockTurnkeyClient
    let adapter = makeAdapter(turnkey: mockTurnkey)

    do {
      _ = try await adapter.getTransactions(chainId: 1, limit: nil, offset: nil, order: nil)
      Issue.record("expected tokenExpired")
    } catch let error as RainError where error == .tokenExpired {
      // Expected: the session error surfaces directly as the typed Rain error.
    }
    #expect(client.getActivitiesCalls.isEmpty)
  }
}
