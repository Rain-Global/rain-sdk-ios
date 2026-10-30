import Testing
import Foundation
import TurnkeySwift
import TurnkeyTypes
import Web3
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// Solana-path tests for the Turnkey adapter, driven through `RainSDKManager`. Stubs that use
/// `MockURLProtocol` run serialized (global registration).
@Suite("Turnkey Solana Adapter Tests", .serialized)
struct TurnkeySolanaTests {
  private static let host = "solana.test"
  private static let rpcUrl = "https://solana.test/rpc"
  private static let chainId = SolanaChains.mainnet // 900
  private static var solanaCaip2: String { SolanaChains.caip2(for: chainId)! }

  private let recipient = Base58.encode((0..<32).map { UInt8($0 + 40) })
  private let blockhash = Base58.encode((0..<32).map { UInt8($0 + 70) })

  private func configs() -> [NetworkConfig] {
    [.testConfig(chainId: Self.chainId, rpcUrl: Self.rpcUrl)]
  }

  private func dualCurveTurnkey() -> MockTurnkey {
    MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
  }

  // MARK: - Address resolution

  @Test("getWalletAddress(chainId:) resolves the Solana account for Solana chains")
  func solanaAddress() async throws {
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: dualCurveTurnkey(), configs: configs())
    let address = try await manager.getWalletAddress(chainId: Self.chainId)
    #expect(address == MockTurnkey.defaultSolanaAddress)
  }

  @Test("getWalletAddress(chainId:) still returns the EVM address for EVM chains")
  func evmAddressUnaffected() async throws {
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: dualCurveTurnkey(), configs: configs())
    let address = try await manager.getWalletAddress(chainId: 1)
    #expect(address == MockTurnkey.defaultWalletAddress)
  }

  // MARK: - Send

  @Test("sendNative on Solana returns the signature from the status response")
  func sendSolanaReturnsSignature() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncluded(signature: "sol-sig-123")]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let result = try await manager.sendNative(chainId: Self.chainId, to: recipient, amount: 0.5)
      #expect(result.transactionHash == "sol-sig-123")

      // The unsigned transaction was built and submitted via sol_send_transaction.
      #expect(client.solSendTransactionCalls.count == 1)
      let body = client.solSendTransactionCalls[0]
      #expect(body.caip2 == Self.solanaCaip2)
      #expect(body.signWith == MockTurnkey.defaultSolanaAddress)
      #expect(SolanaTransactionDecoder.decodeTransfer(body.unsignedTransaction)?.to == recipient)
    }
  }

  @Test("sendNative recovers the signature from chain only when it differs from the pre-send baseline")
  func sendSolanaRecoversNewSignatureFromChain() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncludedWithoutSignature()]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])
      // Pre-send baseline read returns the wallet's older signature; lookups after the send
      // return the one this transaction landed as.
      MockURLProtocol.stub(method: "getSignaturesForAddress", results: [
        [["signature": "old-sig"]],
        [["signature": "new-sig"]]
      ])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let result = try await manager.sendNative(chainId: Self.chainId, to: recipient, amount: 0.5)
      #expect(result.transactionHash == "new-sig")
    }
  }

  @Test("sendNative never reports a pre-existing signature as this send", .timeLimit(.minutes(1)))
  func sendSolanaStaleSignatureFallsBackToStatusId() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncludedWithoutSignature()]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])
      // The chain only ever shows a signature that predates this send, so recovery must be
      // refused and the status id returned instead. Exhausts the retry loop (~7s of real sleeps).
      MockURLProtocol.stub(method: "getSignaturesForAddress", result: [["signature": "old-sig"]])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let result = try await manager.sendNative(chainId: Self.chainId, to: recipient, amount: 0.5)
      #expect(result.transactionHash == "sol-send-status-id")
    }
  }

  // MARK: - History

  @Test("getTransactions on Solana decodes sol_send activities")
  func solanaHistory() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let unsigned = try SolanaTransactionBuilder.buildTransferHex(
      from: MockTurnkey.defaultSolanaAddress, to: recipient,
      lamports: 1_000_000_000, recentBlockhash: blockhash)
    client.mockActivities = [
      MockTurnkey.makeSolanaActivity(
        id: "act-1",
        signWith: MockTurnkey.defaultSolanaAddress,
        caip2: Self.solanaCaip2,
        unsignedTransaction: unsigned,
        sendTransactionStatusId: "status-1")
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

    let txs = try await manager.getTransactions(chainId: Self.chainId, limit: nil, offset: nil, order: nil)
    #expect(txs.count == 1)
    // The activity log carries no on-chain signature, so the row's hash is the status id.
    #expect(txs[0].hash == "status-1")
    #expect(txs[0].to == recipient)
    #expect(txs[0].from == MockTurnkey.defaultSolanaAddress)
    #expect(txs[0].value == 1.0)
    #expect(txs[0].asset == "SOL")
    #expect(txs[0].chainId == Self.chainId)
    #expect(client.getActivitiesCalls[0].filterByType == [.activity_type_sol_send_transaction])
  }

  @Test("getTransactions decodes an SPL send, with the recipient from the ATA creation")
  func solanaSplHistory() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let recipientTokenAccount = try SolanaProgramAddress.associatedTokenAddress(
      owner: recipient, mint: Self.mint, tokenProgramId: SolanaPrograms.splToken)
    let unsigned = try SolanaTransactionBuilder.buildSPLTransferHex(
      owner: MockTurnkey.defaultSolanaAddress,
      source: Self.senderTokenAccount,
      destination: recipientTokenAccount,
      destinationOwner: recipient,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.splToken,
      amount: 2_500_000,
      decimals: 6,
      recentBlockhash: blockhash,
      createDestinationAccount: true
    )
    client.mockActivities = [
      MockTurnkey.makeSolanaActivity(
        id: "act-spl",
        signWith: MockTurnkey.defaultSolanaAddress,
        caip2: Self.solanaCaip2,
        unsignedTransaction: unsigned,
        sendTransactionStatusId: "status-spl")
    ]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let txs = try await manager.getTransactions(
        chainId: Self.chainId, limit: nil, offset: nil, order: nil)
      #expect(txs.count == 1)
      #expect(txs[0].category == .token)
      #expect(txs[0].from == MockTurnkey.defaultSolanaAddress)
      // The wallet, not its token account — recovered from the transaction's ATA creation.
      #expect(txs[0].to == recipient)
      #expect(txs[0].value == Decimal(string: "2.5"))
      #expect(txs[0].tokenAddress == Self.mint)
      #expect(txs[0].rawValue == "2500000")
      #expect(txs[0].decimals == 6)
      #expect(txs[0].chainId == Self.chainId)
      // The token accounts are not reconstructible from `to`, so they ride in metadata.
      #expect(txs[0].metadata?.sourceTokenAccount != nil)
      #expect(txs[0].metadata?.destinationTokenAccount != nil)
    }
  }

  @Test("an SPL send into an existing account resolves the recipient from the node")
  func solanaSplHistoryResolvesOwner() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let unsigned = try SolanaTransactionBuilder.buildSPLTransferHex(
      owner: MockTurnkey.defaultSolanaAddress,
      source: Self.senderTokenAccount,
      destination: Self.recipientTokenAccount,
      destinationOwner: recipient,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.splToken,
      amount: 1_000_000,
      decimals: 6,
      recentBlockhash: blockhash,
      createDestinationAccount: false
    )
    client.mockActivities = [
      MockTurnkey.makeSolanaActivity(
        id: "act-spl-2",
        signWith: MockTurnkey.defaultSolanaAddress,
        caip2: Self.solanaCaip2,
        unsignedTransaction: unsigned,
        sendTransactionStatusId: "status-spl-2")
    ]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", result: [
        "value": [
          "owner": SolanaPrograms.splToken,
          "data": ["parsed": [
            "type": "account",
            "info": [
              "mint": Self.mint,
              "owner": recipient,
              "tokenAmount": ["amount": "0", "decimals": 6]
            ]
          ]]
        ]
      ])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let txs = try await manager.getTransactions(
        chainId: Self.chainId, limit: nil, offset: nil, order: nil)
      #expect(txs[0].to == recipient)
      #expect(txs[0].value == 1)
    }
  }

  // MARK: - Balances

  @Test("getBalance(.native) on Solana reads SOL from Turnkey")
  func solanaNativeBalanceViaTurnkey() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "2000000000",
        caip19: "\(Self.solanaCaip2)/slip44:501",
        decimals: 9,
        name: "Solana",
        symbol: "SOL")
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

    let balance = try await manager.getBalance(chainId: Self.chainId, token: .native)
    #expect(balance.token == .native)
    #expect(balance.symbol == "SOL")
    #expect(balance.decimals == 9)
    #expect(balance.decimalAmount == 2)
    #expect(client.walletAddressBalanceCalls[0].caip2 == Self.solanaCaip2)
    #expect(client.walletAddressBalanceCalls[0].address == MockTurnkey.defaultSolanaAddress)
  }

  @Test("getBalances on Solana falls back to the RPC reader when Turnkey errors")
  func solanaBalancesRpcFallback() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.walletAddressBalancesError = RainError.providerError(
      underlying: NSError(domain: "test", code: 1))

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let balances = try await manager.getTokenBalances(chainId: Self.chainId)
      #expect(balances.count == 1)
      #expect(balances[0].token == .native)
      #expect(balances[0].symbol == "SOL")
      #expect(balances[0].decimalAmount == 1)
    }
  }

  @Test("getBalance for an SPL mint Turnkey does not list falls back to the node")
  func splBalanceRpcFallback() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [] // Turnkey indexes nothing for this cluster.

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 6),
        Self.tokenAccountInfo(amount: "2500000", decimals: 6)
      ])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let balance = try await manager.getBalance(
        chainId: Self.chainId, token: .contract(address: Self.mint))
      #expect(balance.rawAmount == BigUInt(2_500_000))
      #expect(balance.decimals == 6)
      #expect(balance.decimalAmount == Decimal(string: "2.5"))
    }
  }

  @Test("getBalance for an SPL mint Turnkey lists uses Turnkey's amount and metadata")
  func splBalanceTurnkeyFirst() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "100500000",
        caip19: "\(Self.solanaCaip2)/token:\(Self.mint)",
        decimals: 6,
        name: "USD Coin",
        symbol: "USDC")
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

    // No RPC stubs installed: the node is never consulted when Turnkey lists the mint.
    let balance = try await manager.getBalance(
      chainId: Self.chainId, token: .contract(address: Self.mint))
    #expect(balance.rawAmount == BigUInt(100_500_000))
    #expect(balance.decimals == 6)
    #expect(balance.symbol == "USDC")
    #expect(balance.name == "USD Coin")
  }

  @Test("getBalance falls back to the node with registered naming when Turnkey errors")
  func splBalanceFallbackKeepsRegisteredNaming() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.walletAddressBalancesError = RainError.providerError(
      underlying: NSError(domain: "test", code: 1))

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 6),
        Self.tokenAccountInfo(amount: "2500000", decimals: 6)
      ])
      let (manager, _, _) = TestManagers.turnkeyManager(
        turnkey: turnkey,
        configs: configs(),
        registeredTokens: [
          TokenInfo(chainId: Self.chainId, address: Self.mint, symbol: "USDC", decimals: 6, name: "USD Coin")
        ]
      )

      let balance = try await manager.getBalance(
        chainId: Self.chainId, token: .contract(address: Self.mint))
      // Amount from the node; symbol/name from the host registration.
      #expect(balance.rawAmount == BigUInt(2_500_000))
      #expect(balance.symbol == "USDC")
      #expect(balance.name == "USD Coin")
    }
  }

  @Test("getTokenBalances on Solana uses Turnkey's SPL list when it indexes the cluster")
  func splBalancesTurnkeyFirst() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "2000000000",
        caip19: "\(Self.solanaCaip2)/slip44:501",
        decimals: 9,
        name: "Solana",
        symbol: "SOL"),
      v1AssetBalance(
        balance: "100500000",
        caip19: "\(Self.solanaCaip2)/token:\(Self.mint)",
        decimals: 6,
        name: "USD Coin",
        symbol: "USDC")
    ]
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

    // No RPC stubs installed: the node is never consulted when Turnkey lists SPL assets.
    let balances = try await manager.getTokenBalances(chainId: Self.chainId)
    #expect(balances.count == 2)
    #expect(balances[0].token == .native)
    #expect(balances[0].decimalAmount == 2)
    #expect(balances[1].token == .contract(address: Self.mint))
    #expect(balances[1].rawAmount == BigUInt(100_500_000))
    #expect(balances[1].symbol == "USDC")
    #expect(balances[1].name == "USD Coin")
  }

  @Test("getTokenBalances on Solana names a discovered mint from host-registered tokens")
  func splBalancesRegisteredNaming() async throws {
    // When Turnkey does not index the cluster's mints the list comes from node discovery, and
    // `registerTokens` is how a caller labels a mint — otherwise it shows only an address.
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.mockBalances = [
      v1AssetBalance(
        balance: "2000000000",
        caip19: "\(Self.solanaCaip2)/slip44:501",
        decimals: 9,
        name: "Solana",
        symbol: "SOL")
    ]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 2_000_000_000])
      MockURLProtocol.stub(method: "getTokenAccountsByOwner") { params in
        Self.isToken2022(params)
          ? ["value": []]
          : ["value": [Self.tokenAccountRow(pubkey: Self.senderTokenAccount, amount: "2500000", decimals: 6)]]
      }
      let (manager, _, _) = TestManagers.turnkeyManager(
        turnkey: turnkey,
        configs: configs(),
        registeredTokens: [
          TokenInfo(chainId: Self.chainId, address: Self.mint, symbol: "USDC", decimals: 6, name: "USD Coin")
        ]
      )

      let balances = try await manager.getTokenBalances(chainId: Self.chainId)
      let token = try #require(balances.first { $0.token == .contract(address: Self.mint) })
      #expect(token.symbol == "USDC")
      #expect(token.name == "USD Coin")
      #expect(token.rawAmount == BigUInt(2_500_000))
    }
  }

  @Test("getTokenBalances on Solana discovers SPL tokens from the node when Turnkey lists none")
  func splBalancesDiscoveredFromNode() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    // Turnkey answers, but with SOL only — what an unindexed cluster looks like.
    client.mockBalances = [
      v1AssetBalance(
        balance: "2000000000",
        caip19: "\(Self.solanaCaip2)/slip44:501",
        decimals: 9,
        name: "Solana",
        symbol: "SOL")
    ]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getBalance", result: ["value": 2_000_000_000])
      // Answered per token program: the two enumerations run concurrently.
      MockURLProtocol.stub(method: "getTokenAccountsByOwner") { params in
        Self.isToken2022(params)
          ? ["value": []]
          : ["value": [Self.tokenAccountRow(pubkey: Self.senderTokenAccount, amount: "2500000", decimals: 6)]]
      }
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let balances = try await manager.getTokenBalances(chainId: Self.chainId)
      #expect(balances.count == 2)
      #expect(balances[0].token == .native)
      #expect(balances[0].symbol == "SOL")
      #expect(balances[0].decimalAmount == 2)
      #expect(balances[1].token == .contract(address: Self.mint))
      #expect(balances[1].decimalAmount == Decimal(string: "2.5"))
    }
  }

  // MARK: - SPL send
  //
  // Every preflight lives in `SolanaTransferComposer`, so these exercise the composed flow:
  // getAccountInfo × (mint, recipient wallet, source token account, destination token account),
  // then the fee check, blockhash, simulation and Turnkey broadcast.

  /// Stubs the account reads a composed SPL transfer makes, in order.
  private func stubComposerReads(
    mintDecimals: Int = 6,
    tokenProgram: String = SolanaPrograms.splToken,
    sourceAmount: String = "5000000",
    destinationExists: Bool
  ) {
    // The recipient read returns no account: it is a plain wallet, not a token account.
    let noAccount: [String: Any] = ["value": NSNull()]
    let destination: [String: Any] = destinationExists
      ? Self.tokenAccountInfo(amount: "0", decimals: mintDecimals, tokenProgram: tokenProgram)
      : noAccount
    MockURLProtocol.stub(method: "getAccountInfo", results: [
      Self.mintAccountInfo(decimals: mintDecimals, tokenProgram: tokenProgram),
      noAccount,
      Self.tokenAccountInfo(amount: sourceAmount, decimals: mintDecimals, tokenProgram: tokenProgram),
      destination
    ])
    MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000]) // 1 SOL for fees
    MockURLProtocol.stub(method: "getMinimumBalanceForRentExemption", result: 1_488_440)
    MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": blockhash]])
    MockURLProtocol.stub(method: "simulateTransaction", result: ["value": ["err": NSNull(), "logs": []]])
  }

  /// The transfer the adapter should have submitted, built independently from the same inputs.
  private func expectedTransfer(
    amount: UInt64,
    decimals: UInt8,
    tokenProgram: String = SolanaPrograms.splToken,
    createDestination: Bool
  ) throws -> String {
    let source = try SolanaProgramAddress.associatedTokenAddress(
      owner: MockTurnkey.defaultSolanaAddress, mint: Self.mint, tokenProgramId: tokenProgram)
    let destination = try SolanaProgramAddress.associatedTokenAddress(
      owner: recipient, mint: Self.mint, tokenProgramId: tokenProgram)
    return try SolanaTransactionBuilder.buildSPLTransferHex(
      owner: MockTurnkey.defaultSolanaAddress,
      source: source,
      destination: destination,
      destinationOwner: recipient,
      mint: Self.mint,
      tokenProgramId: tokenProgram,
      amount: amount,
      decimals: decimals,
      recentBlockhash: blockhash,
      createDestinationAccount: createDestination
    )
  }

  @Test("sendToken on Solana transfers into the recipient's existing token account")
  func splSendToExistingAccount() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncluded(signature: "spl-sig-1")]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(destinationExists: true)
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      let result = try await manager.sendToken(
        chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1.5, decimals: nil)
      #expect(result.transactionHash == "spl-sig-1")

      #expect(client.solSendTransactionCalls.count == 1)
      let body = client.solSendTransactionCalls[0]
      #expect(body.caip2 == Self.solanaCaip2)
      #expect(body.signWith == MockTurnkey.defaultSolanaAddress)
      // 1.5 tokens at the mint's 6 decimals, no account creation.
      #expect(body.unsignedTransaction == (try expectedTransfer(
        amount: 1_500_000, decimals: 6, createDestination: false)))
      // The transaction was dry-run before it was handed to Turnkey.
      #expect(MockURLProtocol.recordedMethods.contains("simulateTransaction"))
    }
  }

  @Test("sendToken creates the recipient's associated token account when they have none")
  func splSendCreatesRecipientAccount() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncluded(signature: "spl-sig-2")]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(destinationExists: false)
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      _ = try await manager.sendToken(
        chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)

      #expect(client.solSendTransactionCalls[0].unsignedTransaction == (try expectedTransfer(
        amount: 1_000_000, decimals: 6, createDestination: true)))
    }
  }

  @Test("a sponsored-rent send from a zero-SOL wallet creates the recipient's account without reading balance or rent, and the bytes are the self-paid bytes")
  func splSendSponsoredRentFromZeroSolWallet() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncluded(signature: "spl-sig-rent")]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(destinationExists: false)
      MockURLProtocol.stub(method: "getBalance", result: ["value": 0])
      MockURLProtocol.stubError(method: "getMinimumBalanceForRentExemption", error: URLError(.badServerResponse))
      let (manager, _, _) = TestManagers.turnkeyManager(
        turnkey: turnkey, configs: configs(), sponsorGas: true, sponsorRent: true
      )

      _ = try await manager.sendToken(
        chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)

      #expect(!MockURLProtocol.recordedMethods.contains("getBalance"))
      #expect(!MockURLProtocol.recordedMethods.contains("getMinimumBalanceForRentExemption"))
      #expect(!MockURLProtocol.recordedMethods.contains("simulateTransaction"))
      #expect(client.solSendTransactionCalls[0].sponsor == true)
      #expect(client.solSendTransactionCalls[0].unsignedTransaction == (try expectedTransfer(
        amount: 1_000_000, decimals: 6, createDestination: true)))
    }
  }

  @Test("with gas sponsored but not rent, a zero-SOL wallet is still refused the rent up front")
  func splSendGasOnlyStillDemandsRent() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(destinationExists: false)
      MockURLProtocol.stub(method: "getBalance", result: ["value": 0])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs(), sponsorGas: true)

      let error = await #expect(throws: RainError.self) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)
      }
      guard case .insufficientFunds(let required, _) = error else {
        Issue.record("expected insufficientFunds, got \(String(describing: error))")
        return
      }
      #expect(required == "0.00148844", "the rent alone: the fee is sponsored")
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("a Token-2022 mint transfers through its own program")
  func splSendToken2022() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.sendTransactionStatusQueue = [.solanaIncluded(signature: "spl-sig-3")]

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(
        mintDecimals: 2,
        tokenProgram: SolanaPrograms.token2022,
        sourceAmount: "1000",
        destinationExists: false
      )
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      _ = try await manager.sendToken(
        chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 2, decimals: nil)

      #expect(client.solSendTransactionCalls[0].unsignedTransaction == (try expectedTransfer(
        amount: 200, decimals: 2, tokenProgram: SolanaPrograms.token2022, createDestination: true)))
    }
  }

  @Test("sendToken fails before broadcasting when the sender's token balance is short")
  func splSendInsufficientBalance() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(sourceAmount: "1000", destinationExists: true)
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      await #expect(throws: RainError.insufficientTokenBalance(
        requested: "", available: "", token: Self.mint
      )) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 5, decimals: nil)
      }
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("sendToken fails when the sender holds no account for the mint")
  func splSendNoSourceAccount() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 6),
        ["value": NSNull()], // recipient wallet
        ["value": NSNull()]  // no source token account
      ])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      await #expect(throws: RainError.tokenAccountNotFound(
        walletAddress: MockTurnkey.defaultSolanaAddress, token: Self.mint
      )) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)
      }
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("sendToken rejects a recipient that is itself a token account")
  func splSendRejectsTokenAccountRecipient() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      MockURLProtocol.stub(method: "getAccountInfo", results: [
        Self.mintAccountInfo(decimals: 6),
        Self.tokenAccountInfo(amount: "0", decimals: 6) // the "recipient" is a token account
      ])
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      await #expect(throws: RainError.invalidRecipient(address: recipient, reason: "")) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)
      }
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("sendToken surfaces a failed simulation instead of broadcasting")
  func splSendSimulationFailure() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(destinationExists: true)
      MockURLProtocol.stub(
        method: "simulateTransaction",
        result: ["value": ["err": ["InstructionError": [0, "AccountNotFound"]], "logs": ["failed"]]]
      )
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      await #expect(throws: RainError.transactionSimulationFailed(
        underlying: RainError.internalError(details: "")
      )) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)
      }
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("sendToken fails when the wallet cannot cover fees and rent")
  func splSendInsufficientLamports() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      stubComposerReads(destinationExists: false)
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000]) // under the 5000-lamport fee
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      await #expect(throws: RainError.insufficientFunds(required: "", available: "")) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 1, decimals: nil)
      }
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("an amount too large to encode is rejected, not truncated")
  func splSendRejectsOverflowingAmount() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient

    try await MockURLProtocol.withInstalled {
      MockURLProtocol.interceptedHosts = [Self.host]
      // An 18-decimal mint, holding more than u64 can express in base units.
      stubComposerReads(
        mintDecimals: 18,
        sourceAmount: "999999999999999999999999",
        destinationExists: true
      )
      let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

      // 100 tokens at 18 decimals = 1e20 base units, past UInt64.max (~1.8e19). Truncating would
      // have broadcast a transfer of zero that simulates and "succeeds".
      await #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
        _ = try await manager.sendToken(
          chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: 100, decimals: nil)
      }
      #expect(client.solSendTransactionCalls.isEmpty)
    }
  }

  @Test("a negative amount reports its sign, not a decimal-places complaint")
  func splSendRejectsNegativeAmount() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

    do {
      _ = try await manager.sendToken(
        chainId: Self.chainId, contractAddress: Self.mint, to: recipient, amount: -1, decimals: nil)
      Issue.record("expected a negative amount to be rejected")
    } catch let error as RainError {
      #expect(error.errorDescription?.contains("greater than zero") == true)
    }
    #expect(client.solSendTransactionCalls.isEmpty)
  }

  @Test("sendToken rejects a malformed recipient before touching the network")
  func splSendRejectsBadRecipient() async throws {
    let turnkey = dualCurveTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs())

    await #expect(throws: RainError.self) {
      _ = try await manager.sendToken(
        chainId: Self.chainId, contractAddress: Self.mint, to: "not-base58-0OIl", amount: 1, decimals: nil)
    }
    #expect(client.solSendTransactionCalls.isEmpty)
  }

  // MARK: - Fixtures

  private static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

  /// Whether a `getTokenAccountsByOwner` call asked for the Token-2022 program.
  private static func isToken2022(_ params: [Any]) -> Bool {
    (params.dropFirst().first as? [String: Any])?["programId"] as? String == SolanaPrograms.token2022
  }
  private static let senderTokenAccount = "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B"
  private static let recipientTokenAccount = "DJcjpsHnWXSucjUpourygEN3mkcQwSHG6d5b2AzLSfSn"

  private static func tokenAccountRow(
    pubkey: String,
    amount: String,
    decimals: Int,
    mint: String = TurnkeySolanaTests.mint
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
  private static func tokenAccountInfo(
    amount: String,
    decimals: Int,
    tokenProgram: String = SolanaPrograms.splToken
  ) -> [String: Any] {
    ["value": [
      "owner": tokenProgram,
      "data": ["parsed": [
        "type": "account",
        "info": [
          "mint": mint,
          "owner": MockTurnkey.defaultSolanaAddress,
          "tokenAmount": ["amount": amount, "decimals": decimals]
        ]
      ]]
    ]]
  }

  private static func mintAccountInfo(
    decimals: Int,
    tokenProgram: String = SolanaPrograms.splToken
  ) -> [String: Any] {
    ["value": [
      "owner": tokenProgram,
      "data": ["parsed": ["type": "mint", "info": ["decimals": decimals]]]
    ]]
  }
}
