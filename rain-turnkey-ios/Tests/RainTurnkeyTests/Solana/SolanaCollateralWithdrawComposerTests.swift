import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// End-to-end composition test against real devnet fixtures: the account data, addresses,
/// signature, and salt are the ones from the first successful withdrawal on devnet
/// (tx `3ByKrsXW…`, 2026-07-24), so the asserted bytes are known-good on chain.
///
/// Fixed fixtures pinned to an exact serialization, so a divergence in the
/// composition shows up as a failing assertion rather than a rejected transaction.
@Suite("Solana Collateral Withdraw Composer Tests", .serialized)
struct SolanaCollateralWithdrawComposerTests {
  private static let host = "solana-devnet.test"
  private static let rpcUrl = "https://solana-devnet.test/rpc"

  private let devnet = SolanaChains.devnet
  private let owner = "3mhBCgFYhFCAV7LFARCcLuLsQLsyErTRc2axkGJrf8UG"
  private let collateral = "2h5mCXyirbPJZbjGcWf4PTpcA6M7qZ5UCRaWysHjnx31"
  private let coordinator = "FF3tTZ91aRu7XdGc4XK6V7MkDyStJ5ZY2fG4ZKLqFgL5"
  private let programId = "A7oUtbpm2pYNeZGNjit9GCGcAQViBbPCuLEnMbu2h15o"
  private let mint = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  private let executor = "8pyuGBnfbCADScManuTtA23mjXmJDbzpgPw2R8tmC6gz"

  // Raw devnet account data (base64), captured at nonce 0 — the state the golden signature was
  // issued against (each withdrawal increments the nonce). The coordinator account is trimmed
  // after its executors vec — the tail is zero padding the parser never reads.
  private let collateralData =
    "Ey1jHcQy5HWnOHdO2T7CRNZhoZwZh0GwPo0mfagjVsGsGY2fH2KNQdOdA0tPmQtwpGjhDAwipRkO8lD4NVfOJV"
    + "/RXV0o8Rpe/xAAAABDb2xsYXRlcmFsU29sYW5hAAAAACkqW0Gb6ozWxe84Me0JM3doSAivumoFOfoMu8/P1wIJ"
    + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  private let coordinatorData =
    "6oU9jK0DCrzAoMFbwn0Q6d70hJIK+xVVS4OxJMbo8DRXrUOATrTXxfui23QolaNZqiC5e3ewk/8MoAZzSNsL9t"
    + "bAQuHebigSnnRMcds6qirVTZcs6HKcRHzH1X4n9VGUYjoe3yFFLRzbsSbOmUylDJFRAmO2VHDQYCYlBDbv92RQ"
    + "WtrjlmDjgMgBAAAAdExx2zqqKtVNlyzocpxEfMfVfif1UZRiOh7fIUUtHNsBAAAAdExx2zqqKtVNlyzocpxEfM"
    + "fVfif1UZRiOh7fIUUtHNs="

  /// The full unsigned transaction these fixtures compose to, verified byte-for-byte against the
  /// composer. Pinned so any drift in the serialization is caught by a unit test.
  private static let goldenWithdrawTransactionHex =
    "010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    + "00000000000000000000000000000000000100070c292a5b419bea8cd6c5ef3831ed093377684808afba6a0539fa0cbb"
    + "cfcfd7020919204dc2efd47006f5f095dfcfff8c2811bdb39f9bd6e7ea149dc2036ea28e589ab92d4c9217f2ea4521db"
    + "018240fdf2b101512b607ae3e0a1346634f799dcf05fe8b40a3afbbe885fda41ee87fa5e3c3c519ae399616b2d492c60"
    + "5ffbe1f9698642eb182389419107cce6e26289dfe20d8884d912cde4a886035373d3351eb1d39d034b4f990b70a468e1"
    + "0c0c22a5190ef250f83557ce255fd15d5d28f11a5e3b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b77906"
    + "08df002ea706ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a906a7d517187bd16635dad4"
    + "0455fdc2c0c124c68f215675a5dbbacb5f08000000000000000000000000000000000000000000000000000000000000"
    + "0000000000037d46d67c93fbbe12f9428f838d40ff0570744927f48a64fcca70448000000087773927c913f674c8e5fb"
    + "da44d29773d1d3e89532e3aa88de306103d95eca663b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b77906"
    + "08df002ea7020a00900101003000ffff1000ffff70002000ffff744c71db3aaa2ad54d972ce8729c447cc7d57e27f551"
    + "94623a1edf21452d1cdb4d1302f27a2e3c15f385ce2c8ac622a2d35f11bb07029186af5d40edac4562ed6b3152a9c19e"
    + "a20ba5e851fb92ed1cb0abfd2c10318bb546c533d0d18925590377229dff3a1aca1bf472323ba0cdf247669970593ab8"
    + "f64b31d7e1e74d28e8f40b0b0005010200060304070809380d1940536fb846f10100000000000000db98636a00000000"
    + "4d04340a6744e9f749ce2e9a165e97ebc00a4c44e06162a63eea0abd6a416f9c"

  private var adminSignature: RainAdminSignature {
    RainAdminSignature(
      salt: "TQQ0CmdE6fdJzi6aFl6X68AKTETgYWKmPuoKvWpBb5w=",
      signature: "TRMC8nouPBXzhc4sisYiotNfEbsHApGGr11A7axFYu1rMVKpwZ6iC6XoUfuS7Rywq"
        + "/0sEDGLtUbFM9DRiSVZAw==",
      expiresAt: "2026-07-24T16:54:51.000Z" // epoch 1784912091, as signed
    )
  }

  private func makeComposer() -> SolanaCollateralWithdrawComposer {
    SolanaCollateralWithdrawComposer(
      rpcClient: SolanaRpcClient(
        networkConfigs: [.testConfig(chainId: SolanaChains.devnet, rpcUrl: Self.rpcUrl)]
      )
    )
  }

  /// The destination ATA for (owner, mint) under the classic token program.
  private func destinationAta() throws -> String {
    try SolanaProgramAddress.associatedTokenAddress(
      owner: owner,
      mint: mint,
      tokenProgramId: SolanaPrograms.splToken
    )
  }

  /// Answers `getAccountInfo` by the address asked for; `collateralOverride` swaps the collateral
  /// account's bytes. Only `Sendable` values are captured, so the maps hold plain strings and the
  /// response objects are built inside the closure.
  private func stubHappyPath(collateralOverride: String? = nil) throws {
    MockURLProtocol.interceptedHosts = [Self.host]

    let ata = try destinationAta()
    let tokenProgram = SolanaPrograms.splToken
    // address → (owning program, base64 data). The recipient's token account already exists, so
    // any non-null account will do for it.
    let rawData: [String: String] = [
      collateral: collateralOverride ?? collateralData,
      coordinator: coordinatorData,
      ata: ""
    ]
    let rawOwners: [String: String] = [
      collateral: programId,
      coordinator: programId,
      ata: tokenProgram
    ]
    let mintAddress = mint

    MockURLProtocol.stub(method: "getAccountInfo") { params in
      guard let address = params.first as? String else { return ["value": NSNull()] }
      if address == mintAddress {
        return [
          "value": [
            "owner": tokenProgram,
            "lamports": 1_461_600,
            "data": ["parsed": ["type": "mint", "info": ["decimals": 6]]]
          ] as [String: Any]
        ]
      }
      guard let data = rawData[address], let ownerProgram = rawOwners[address] else {
        return ["value": NSNull()]
      }
      return [
        "value": [
          "owner": ownerProgram,
          "lamports": 2_122_800,
          "data": [data, "base64"]
        ] as [String: Any]
      ]
    }
    MockURLProtocol.stub(method: "getLatestBlockhash", result: ["value": ["blockhash": mint]])
    MockURLProtocol.stub(method: "simulateTransaction", result: ["value": ["err": NSNull(), "logs": []]])
    MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000])
    MockURLProtocol.stub(method: "getMinimumBalanceForRentExemption", result: 1_488_440)
  }

  /// `stubHappyPath` with no token account at the recipient's ATA, so the withdrawal creates it.
  private func stubRecipientWithoutTokenAccount() throws {
    try stubHappyPath()
    let ata = try destinationAta()
    let tokenProgram = SolanaPrograms.splToken
    let rawData: [String: String] = [collateral: collateralData, coordinator: coordinatorData]
    let rawOwners: [String: String] = [collateral: programId, coordinator: programId]
    let mintAddress = mint
    MockURLProtocol.stub(method: "getAccountInfo") { params in
      guard let address = params.first as? String, address != ata else { return ["value": NSNull()] }
      if address == mintAddress {
        return [
          "value": [
            "owner": tokenProgram,
            "lamports": 1_461_600,
            "data": ["parsed": ["type": "mint", "info": ["decimals": 6]]]
          ] as [String: Any]
        ]
      }
      guard let data = rawData[address], let ownerProgram = rawOwners[address] else {
        return ["value": NSNull()]
      }
      return ["value": ["owner": ownerProgram, "lamports": 2_122_800, "data": [data, "base64"]] as [String: Any]]
    }
  }

  @Test("composes the two-instruction withdrawal the program accepted on devnet")
  func testComposesDevnetAcceptedWithdrawal() async throws {
    try await MockURLProtocol.withInstalled {
      try stubHappyPath()

      let unsigned = try await makeComposer().composeWithdraw(
        chainId: devnet,
        ownerAddress: owner,
        collateralAddress: collateral,
        mintAddress: mint,
        recipientAddress: owner,
        amountBaseUnits: 1,
        adminSignature: adminSignature
      )

      let hex = unsigned.transactionHex
      // Golden: the full serialized transaction for these exact fixtures, so
      // a composition change on either platform fails here instead of on chain. Deterministic
      // because the stubbed blockhash is fixed.
      #expect(hex == Self.goldenWithdrawTransactionHex)
      // The ed25519 instruction embeds the executor key, Rain's signature, and the exact 32-byte
      // message the executor signed — verified against the live signature.
      #expect(hex.contains(SolanaTransactionBuilder.hexEncode(try Base58.decode(executor))))
      #expect(hex.contains("77229dff3a1aca1bf472323ba0cdf247669970593ab8f64b31d7e1e74d28e8f4"))
      // The withdraw instruction: discriminator, then amount=1 and expiry 1784912091
      // (0x6A6398DB) as LE u64/i64.
      #expect(hex.contains("0d1940536fb846f1" + "0100000000000000" + "db98636a00000000"))
      // Both programs are in the account table; the owner is the fee payer.
      #expect(hex.contains(SolanaTransactionBuilder.hexEncode(try Base58.decode(programId))))
      #expect(
        hex.contains(
          SolanaTransactionBuilder.hexEncode(try Base58.decode(SolanaPrograms.ed25519Verify))
        )
      )
      #expect(unsigned.createsRecipientAccount == false)
    }
  }

  @Test("rejects a wallet that does not own the collateral")
  func testRejectsNonOwner() async throws {
    try await MockURLProtocol.withInstalled {
      try stubHappyPath()

      await #expect(
        throws: RainError.walletNotAuthorized(walletAddress: executor, proxyAddress: collateral)
      ) {
        _ = try await makeComposer().composeWithdraw(
          chainId: devnet,
          ownerAddress: executor, // any wallet that isn't the collateral's owner
          collateralAddress: collateral,
          mintAddress: mint,
          recipientAddress: owner,
          amountBaseUnits: 1,
          adminSignature: adminSignature
        )
      }
    }
  }

  @Test("rejects a collateral account that is not single-signer")
  func testRejectsNonSingleSigner() async throws {
    try await MockURLProtocol.withInstalled {
      // The coordinator account has a different Anchor discriminator — a realistic wrong type.
      try stubHappyPath(collateralOverride: coordinatorData)

      await #expect(throws: RainError.self) {
        _ = try await makeComposer().composeWithdraw(
          chainId: devnet,
          ownerAddress: owner,
          collateralAddress: collateral,
          mintAddress: mint,
          recipientAddress: owner,
          amountBaseUnits: 1,
          adminSignature: adminSignature
        )
      }
    }
  }

  @Test("withdrawCollateral routes a Solana chainId through the composer and the provider")
  func testManagerRoutesSolanaWithdrawal() async throws {
    try await MockURLProtocol.withInstalled {
      try stubHappyPath()

      // The wallet must be the collateral's real owner or the ownership check rejects it.
      let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet(solanaAddress: owner)])
      let client = turnkey.turnkeyClient as! MockTurnkeyClient
      client.sendTransactionStatusQueue = [.solanaIncluded(signature: "sol-withdraw-sig")]

      let (manager, _, _) = TestManagers.turnkeyManager(
        turnkey: turnkey,
        configs: [.testConfig(chainId: SolanaChains.devnet, rpcUrl: Self.rpcUrl)]
      )

      let signature = try await manager.withdrawCollateral(
        chainId: devnet,
        addresses: RainWithdrawAddresses(
          // On Solana the "proxy" is the collateral account and the token is the SPL mint;
          // controllerAddress is unused because there is no coordinator contract to call.
          proxyAddress: collateral,
          controllerAddress: collateral,
          tokenAddress: mint,
          recipientAddress: owner
        ),
        amount: Decimal(string: "0.000001")!, // 1 base unit at 6 decimals
        decimals: 6,
        adminSignature: adminSignature
      )

      #expect(signature == "sol-withdraw-sig")
      // The EVM path was not taken: no eth_sendTransaction, one sol_send_transaction.
      #expect(client.ethSendTransactionCalls.isEmpty)
      #expect(client.solSendTransactionCalls.count == 1)
      // The provider signed exactly the bytes core composed and simulated.
      let submitted = try #require(client.solSendTransactionCalls.first)
      #expect(
        submitted.unsignedTransaction
          .contains("77229dff3a1aca1bf472323ba0cdf247669970593ab8f64b31d7e1e74d28e8f4")
      )
    }
  }

  @Test("prepareWithdrawal hands back the exact bytes withdrawCollateral submits, with its blockhash")
  func testPrepareSolanaWithdrawalMatchesBroadcastBytes() async throws {
    try await MockURLProtocol.withInstalled {
      try stubHappyPath()

      let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet(solanaAddress: owner)])
      let client = turnkey.turnkeyClient as! MockTurnkeyClient
      client.sendTransactionStatusQueue = [.solanaIncluded(signature: "sol-withdraw-sig")]

      let (manager, _, _) = TestManagers.turnkeyManager(
        turnkey: turnkey,
        configs: [.testConfig(chainId: SolanaChains.devnet, rpcUrl: Self.rpcUrl)]
      )
      let addresses = RainWithdrawAddresses(
        proxyAddress: collateral,
        controllerAddress: collateral,
        tokenAddress: mint,
        recipientAddress: owner
      )

      let prepared = try await manager.prepareWithdrawal(
        chainId: devnet,
        addresses: addresses,
        amount: Decimal(string: "0.000001")!,
        decimals: 6,
        adminSignature: adminSignature
      )
      let transfer = try #require(prepared.solanaTransfer)

      // Preparing broadcasts nothing, and the blockhash survives — the field the old
      // `String?`-shaped result had nowhere to put.
      #expect(client.solSendTransactionCalls.isEmpty)
      #expect(!transfer.recentBlockhash.isEmpty)

      _ = try await manager.withdrawCollateral(
        chainId: devnet,
        addresses: addresses,
        amount: Decimal(string: "0.000001")!,
        decimals: 6,
        adminSignature: adminSignature
      )
      let submitted = try #require(client.solSendTransactionCalls.first)

      #expect(transfer.transactionHex == submitted.unsignedTransaction)
    }
  }

  @Test("surfaces a simulation failure instead of handing the transaction out")
  func testSurfacesSimulationFailure() async throws {
    try await MockURLProtocol.withInstalled {
      try stubHappyPath()
      MockURLProtocol.stub(
        method: "simulateTransaction",
        result: ["value": ["err": ["InstructionError": []], "logs": ["Program log: signature expired"]]]
      )

      await #expect(
        throws: RainError.transactionSimulationFailed(
          underlying: RainError.internalError(details: "")
        )
      ) {
        _ = try await makeComposer().composeWithdraw(
          chainId: devnet,
          ownerAddress: owner,
          collateralAddress: collateral,
          mintAddress: mint,
          recipientAddress: owner,
          amountBaseUnits: 1,
          adminSignature: adminSignature
        )
      }
    }
  }

  @Test("a dry run the runtime refuses for a lamport shortfall is insufficientFunds, not a program revert")
  func testSimulationShortfallIsInsufficientFunds() async throws {
    try await MockURLProtocol.withInstalled {
      try stubHappyPath()
      MockURLProtocol.stub(
        method: "simulateTransaction",
        result: ["value": ["err": ["InsufficientFundsForRent": ["account_index": 1]], "logs": []]]
      )

      await #expect(throws: RainError.insufficientFunds(required: "", available: "")) {
        _ = try await makeComposer().composeWithdraw(
          chainId: devnet,
          ownerAddress: owner,
          collateralAddress: collateral,
          mintAddress: mint,
          recipientAddress: owner,
          amountBaseUnits: 1,
          adminSignature: adminSignature
        )
      }
    }
  }

  @Test("a self-paid withdrawal that creates the recipient's account reads the rent from the cluster and demands it up front")
  func testSelfPaidRentReadFromCluster() async throws {
    try await MockURLProtocol.withInstalled {
      try stubRecipientWithoutTokenAccount()
      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000])

      let error = await #expect(throws: RainError.self) {
        _ = try await makeComposer().composeWithdraw(
          chainId: devnet,
          ownerAddress: owner,
          collateralAddress: collateral,
          mintAddress: mint,
          recipientAddress: owner,
          amountBaseUnits: 1,
          adminSignature: adminSignature
        )
      }
      guard case .insufficientFunds(let required, _) = error else {
        Issue.record("expected insufficientFunds, got \(String(describing: error))")
        return
      }
      #expect(required == "0.00149344", "5,000 fee + 1,488,440 rent, in SOL")
      #expect(MockURLProtocol.recordedParams.contains { $0.first as? Int == 165 }, "the classic token account size")
      #expect(!MockURLProtocol.recordedMethods.contains("simulateTransaction"), "refused before the dry run")
    }
  }

  @Test("a sponsored withdrawal that creates the recipient's account reads neither rent nor balance, with the same bytes")
  func testSponsoredRentSkipsTheChecks() async throws {
    try await MockURLProtocol.withInstalled {
      try stubRecipientWithoutTokenAccount()
      MockURLProtocol.stubError(method: "getBalance", error: URLError(.badServerResponse))
      MockURLProtocol.stubError(method: "getMinimumBalanceForRentExemption", error: URLError(.badServerResponse))

      let sponsored = try await makeComposer().composeWithdraw(
        chainId: devnet,
        ownerAddress: owner,
        collateralAddress: collateral,
        mintAddress: mint,
        recipientAddress: owner,
        amountBaseUnits: 1,
        adminSignature: adminSignature,
        sponsoredFees: true,
        sponsoredRent: true
      )
      #expect(sponsored.createsRecipientAccount)
      #expect(!MockURLProtocol.recordedMethods.contains("getBalance"))
      #expect(!MockURLProtocol.recordedMethods.contains("getMinimumBalanceForRentExemption"))

      MockURLProtocol.stub(method: "getBalance", result: ["value": 1_000_000_000])
      MockURLProtocol.stub(method: "getMinimumBalanceForRentExemption", result: 1_488_440)
      let selfPaid = try await makeComposer().composeWithdraw(
        chainId: devnet,
        ownerAddress: owner,
        collateralAddress: collateral,
        mintAddress: mint,
        recipientAddress: owner,
        amountBaseUnits: 1,
        adminSignature: adminSignature
      )
      #expect(sponsored.transaction == selfPaid.transaction)
    }
  }

  @Test("a sponsored provider's withdrawal skips the rent only when the provider also sponsors rent; a preparation never does")
  func testManagerCombinesTheTwoFlags() async throws {
    try await MockURLProtocol.withInstalled {
      try stubRecipientWithoutTokenAccount()
      MockURLProtocol.stub(method: "getBalance", result: ["value": 0]) // a zero-SOL wallet
      let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet(solanaAddress: owner)])
      let client = turnkey.turnkeyClient as! MockTurnkeyClient
      client.sendTransactionStatusQueue = [.solanaIncluded(signature: "sig-1"), .solanaIncluded(signature: "sig-2")]
      let addresses = RainWithdrawAddresses(
        proxyAddress: collateral, controllerAddress: collateral, tokenAddress: mint, recipientAddress: owner
      )
      let configs: [NetworkConfig] = [.testConfig(chainId: SolanaChains.devnet, rpcUrl: Self.rpcUrl)]

      let (feesOnly, _, _) = TestManagers.turnkeyManager(turnkey: turnkey, configs: configs, sponsorGas: true)
      await #expect(throws: RainError.insufficientFunds(required: "", available: "")) {
        _ = try await feesOnly.withdrawCollateral(
          chainId: devnet, addresses: addresses, amount: Decimal(string: "0.000001")!, decimals: 6,
          adminSignature: adminSignature
        )
      }

      let (both, _, _) = TestManagers.turnkeyManager(
        turnkey: turnkey, configs: configs, sponsorGas: true, sponsorRent: true
      )
      let signature = try await both.withdrawCollateral(
        chainId: devnet, addresses: addresses, amount: Decimal(string: "0.000001")!, decimals: 6,
        adminSignature: adminSignature
      )
      #expect(signature == "sig-1")

      await #expect(throws: RainError.insufficientFunds(required: "", available: "")) {
        _ = try await both.prepareWithdrawal(
          chainId: devnet, addresses: addresses, amount: Decimal(string: "0.000001")!, decimals: 6,
          adminSignature: adminSignature
        )
      }
    }
  }
}
