import Foundation
import Web3

/// Composes the withdrawal transaction for Rain's Solana collateral program (single-signer
/// accounts, program v2.02).
///
/// A withdrawal is authorized by two parties: the collateral **owner** signs the transaction
/// itself (the wallet provider does this), and Rain's **coordinator executor** signs a
/// keccak-encoded withdraw message off chain — returned by the Rain API as the admin signature.
/// The transaction therefore carries two instructions:
///
///  1. a native ed25519-program instruction proving the executor signed the withdraw message,
///     which the collateral program reads back through the instructions sysvar, and
///  2. the program's `withdraw_single_signer_collateral_asset` instruction.
///
/// Everything the message and instruction need is read from the chain (collateral account,
/// coordinator executors, mint's token program) or derived locally (the collateral-authority PDA,
/// associated token accounts), so callers supply only the withdrawal parameters and the Rain
/// signature. The composed transaction is simulated before being handed to the wallet provider.
internal struct SolanaCollateralWithdrawComposer: Sendable {
  private static let collateralAuthoritySeed = Array("CollateralAuthority".utf8)

  private let rpcClient: SolanaRpcClient

  init(rpcClient: SolanaRpcClient) {
    self.rpcClient = rpcClient
  }

  /// The owner stays the created account's payer whether or not rent is sponsored; Turnkey
  /// pre-funds the payer, not a separate account.
  func composeWithdraw(
    chainId: Int,
    ownerAddress: String,
    collateralAddress: String,
    mintAddress: String,
    recipientAddress: String,
    amountBaseUnits: BigUInt,
    adminSignature: RainAdminSignature,
    sponsoredFees: Bool = false,
    sponsoredRent: Bool = false
  ) async throws -> UnsignedSolanaTransfer {
    let ownerKey = try decodeKey(ownerAddress, label: "owner")
    let collateralKey = try decodeKey(collateralAddress, label: "collateral")
    let mintKey = try decodeKey(mintAddress, label: "mint")
    let recipientKey = try decodeKey(recipientAddress, label: "recipient")

    // The collateral account tells us everything Rain's program needs: which program owns it (the
    // program id is not part of the API contract), its coordinator, and the nonce the coordinator
    // signature was issued against.
    guard let collateralAccount = try await rpcClient.getRawAccount(
      chainId: chainId,
      address: collateralAddress
    ) else {
      throw RainError.invalidConfig(
        details: "No collateral account at \(collateralAddress) on chainId=\(chainId)"
      )
    }
    let programId = collateralAccount.ownerProgram
    _ = try decodeKey(programId, label: "collateral program")

    guard let collateral = SolanaCollateralAccounts.parseSingleSigner(collateralAccount.data) else {
      throw RainError.internalError(
        details: "Collateral \(collateralAddress) is not a single-signer account; only "
          + "single-signer Solana collateral is supported"
      )
    }
    guard collateral.owner == ownerKey else {
      throw RainError.walletNotAuthorized(
        walletAddress: ownerAddress,
        proxyAddress: collateralAddress
      )
    }

    let coordinatorAddress = Base58.encode(collateral.coordinator)
    guard let coordinatorAccount = try await rpcClient.getRawAccount(
      chainId: chainId,
      address: coordinatorAddress
    ) else {
      throw RainError.internalError(
        details: "Coordinator account missing for \(collateralAddress)"
      )
    }
    guard let executor = try SolanaCollateralAccounts
      .parseCoordinatorExecutors(coordinatorAccount.data).first else {
      throw RainError.internalError(
        details: "Coordinator has no executors to verify the Rain signature against"
      )
    }

    let salt = try decodeBase64(adminSignature.salt, label: "signature salt", expectedSize: 32)
    let signature = try decodeBase64(adminSignature.signature, label: "signature", expectedSize: 64)
    let expiresAtEpochSeconds = try parseExpiresAt(adminSignature.expiresAt)

    guard let mint = try await rpcClient.getMintInfo(chainId: chainId, mint: mintAddress) else {
      throw RainError.tokenNotFound(token: mintAddress, chainId: chainId)
    }

    // Funds are held in the ATA of the collateral-authority PDA (the API's depositAddress).
    let authority = Base58.encode(
      try SolanaProgramAddress.findProgramAddress(
        seeds: [Self.collateralAuthoritySeed, collateralKey],
        programId: try decodeKey(programId, label: "collateral program")
      ).address
    )
    let sourceAta = try SolanaProgramAddress.associatedTokenAddress(
      owner: authority,
      mint: mintAddress,
      tokenProgramId: mint.tokenProgramId
    )
    let destinationAta = try SolanaProgramAddress.associatedTokenAddress(
      owner: recipientAddress,
      mint: mintAddress,
      tokenProgramId: mint.tokenProgramId
    )
    let createDestination = try await !rpcClient.accountExists(
      chainId: chainId,
      address: destinationAta
    )
    try await SolanaLamportPreflight.require(
      rpcClient: rpcClient,
      chainId: chainId,
      address: ownerAddress,
      includeAccountRent: createDestination,
      feesSponsored: sponsoredFees,
      rentSponsored: sponsoredRent
    )

    // Reconstruct the exact message the executor signed; the program re-derives it on chain and
    // requires the ed25519 instruction to have verified precisely these bytes.
    let message = SolanaWithdrawMessages.coordinatorWithdrawMessage(
      coordinator: collateral.coordinator,
      collateral: collateralKey,
      sender: ownerKey,
      receiver: recipientKey,
      asset: mintKey,
      amountBaseUnits: amountBaseUnits,
      nonce: collateral.nonce,
      expiresAtEpochSeconds: expiresAtEpochSeconds,
      salt: salt
    )

    var instructions: [SolanaTransactionBuilder.Instruction] = []
    if createDestination {
      instructions.append(
        SolanaInstructions.createAssociatedTokenAccountIdempotent(
          tokenProgramId: mint.tokenProgramId,
          payer: ownerAddress,
          associatedAccount: destinationAta,
          owner: recipientAddress,
          mint: mintAddress
        )
      )
    }
    // The ed25519 instruction must directly precede the withdraw so the program can find the
    // verified message through the instructions sysvar.
    instructions.append(
      try SolanaInstructions.ed25519Verify(
        signer: executor,
        signature: signature,
        message: message
      )
    )
    instructions.append(
      try SolanaInstructions.withdrawSingleSignerCollateralAsset(
        programId: programId,
        owner: ownerAddress,
        coordinator: coordinatorAddress,
        collateral: collateralAddress,
        collateralAuthority: authority,
        destination: recipientAddress,
        asset: mintAddress,
        collateralTokenAccount: sourceAta,
        destinationTokenAccount: destinationAta,
        tokenProgramId: mint.tokenProgramId,
        amountBaseUnits: amountBaseUnits,
        expiresAtEpochSeconds: expiresAtEpochSeconds,
        coordinatorSignatureSalt: salt
      )
    )

    let blockhash = try await rpcClient.getLatestBlockhash(chainId: chainId)
    let transaction = try SolanaTransactionBuilder.buildTransactionBytes(
      feePayer: ownerAddress,
      recentBlockhash: blockhash,
      instructions: instructions,
      // Sponsored sends can require the System Program among the static keys (see the SPL
      // composer); the withdraw instructions already reference it, so this is a no-op there.
      extraReadonlyKeys: sponsoredFees ? [SolanaPrograms.system] : []
    )
    // The dry run charges the fee to the owner, so a sponsored withdrawal from a zero-SOL wallet
    // would false-fail here even though the sponsor pays the real send. Without it a program
    // rejection is only discovered after signing, from the provider's send status: the adapter
    // maps a status carrying the decoded revert to `transactionSimulationFailed`, so the host
    // still sees `withdrawalRevertedByNetwork` — just later.
    if !sponsoredFees {
      try await simulate(chainId: chainId, transaction: transaction)
    }

    RainLogger.info(
      "Rain SDK: composed Solana collateral withdrawal of \(amountBaseUnits) base units of "
        + "\(mintAddress) to \(recipientAddress) (chainId=\(chainId))"
    )
    return UnsignedSolanaTransfer(
      transaction: transaction,
      recentBlockhash: blockhash,
      createsRecipientAccount: createDestination
    )
  }

  // MARK: - Helpers

  /// `expiresAt` arrives as ISO-8601 from the Rain API; accept a raw epoch too, defensively.
  private func parseExpiresAt(_ value: String) throws -> Int64 {
    if let seconds = Int64(value) { return seconds }
    if let date = RainSdk.parseISO8601(value) { return Int64(date.timeIntervalSince1970) }
    throw RainError.internalError(details: "Unparseable signature expiry: '\(value)'")
  }

  private func decodeBase64(_ value: String, label: String, expectedSize: Int) throws -> [UInt8] {
    guard let data = Data(base64Encoded: value) else {
      throw RainError.internalError(details: "Rain \(label) is not valid base64")
    }
    guard data.count == expectedSize else {
      throw RainError.internalError(
        details: "Rain \(label) must be \(expectedSize) bytes, got \(data.count)"
      )
    }
    return [UInt8](data)
  }

  private func decodeKey(_ address: String, label: String) throws -> [UInt8] {
    let bytes = (try? Base58.decode(address)) ?? []
    guard bytes.count == 32 else {
      throw RainError.internalError(details: "Invalid Solana \(label) address: \(address)")
    }
    return bytes
  }

  private func simulate(chainId: Int, transaction: [UInt8]) async throws {
    let simulation = try await rpcClient.simulateTransaction(
      chainId: chainId,
      base64Transaction: Data(transaction).base64EncodedString()
    )
    if simulation.succeeded { return }
    if simulation.fundsShortfall {
      throw RainError.insufficientFunds(required: "unknown", available: "unknown")
    }
    RainLogger.error(
      "Rain SDK: Solana withdrawal simulation failed: \(simulation.error ?? "unknown"); "
        + "logs: \(simulation.logs.joined(separator: " | "))"
    )
    throw RainError.transactionSimulationFailed(
      underlying: RainError.internalError(
        details: simulation.error ?? "Solana withdrawal simulation failed"
      )
    )
  }
}

/// Keccak-encoded messages for Rain's Solana collateral program — the same EIP-712-shaped
/// construction the EVM contracts use, transplanted onto Solana (addresses are 32-byte ed25519
/// keys, and the signature is ed25519 rather than secp256k1).
///
/// The domain's `chainId` is the fixed constant 900 on every cluster — Rain's Solana *mainnet*
/// id — because the deployed programs bake it into their domain hash. The Rain API's chain
/// routing (900/901) is unrelated to this value. Verified against a live devnet coordinator
/// signature: only 900 validates.
internal enum SolanaWithdrawMessages {
  private static let domainChainId: UInt64 = 900

  private static let domainTypeHash = keccak(
    Array("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)".utf8)
  )
  private static let coordinatorWithdrawTypeHash = keccak(
    Array(("Withdraw(address user,address collateral,address asset,uint256 amount,"
      + "address recipient,uint256 nonce,uint256 expiresAt)").utf8)
  )

  /// The 32-byte message Rain's coordinator executor signs to authorize a single-signer
  /// withdrawal: `keccak(0x1901 ‖ domainSeparator("Coordinator") ‖ structHash)`.
  static func coordinatorWithdrawMessage(
    coordinator: [UInt8],
    collateral: [UInt8],
    sender: [UInt8],
    receiver: [UInt8],
    asset: [UInt8],
    amountBaseUnits: BigUInt,
    nonce: UInt32,
    expiresAtEpochSeconds: Int64,
    salt: [UInt8]
  ) -> [UInt8] {
    let domain = keccak(
      domainTypeHash
        + keccak(Array("Coordinator".utf8))
        + keccak(Array("2".utf8))
        + u64(domainChainId)
        + coordinator
        + salt
    )
    let structHash = keccak(
      coordinatorWithdrawTypeHash
        + sender
        + collateral
        + asset
        + u64(amountBaseUnits)
        + receiver
        + u32(nonce)
        + u64(UInt64(bitPattern: expiresAtEpochSeconds))
    )
    return keccak([0x19, 0x01] + domain + structHash)
  }

  private static func keccak(_ data: [UInt8]) -> [UInt8] {
    [UInt8](Data(data).sha3(.keccak256))
  }

  /// Big-endian, fixed width — matching the reference encoder's zero-padded hex.
  private static func u64(_ value: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    for i in 0..<8 {
      out[7 - i] = UInt8(truncatingIfNeeded: value >> (8 * i))
    }
    return out
  }

  private static func u64(_ value: BigUInt) -> [UInt8] {
    // A u64-range amount is guaranteed by the instruction builder, which rejects anything wider.
    u64(UInt64(clamping: value))
  }

  private static func u32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value >> 24),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value)
    ]
  }
}

/// Minimal borsh readers for the two collateral-program accounts a withdrawal needs. Layouts
/// follow the program's Anchor IDL (v2.02); each account starts with Anchor's 8-byte
/// discriminator (`sha256("account:<Name>")[0..8]`), which is how the account type is checked.
internal enum SolanaCollateralAccounts {
  /// IDL: [19, 45, 99, 29, 196, 50, 228, 117]
  private static let singleSignerDiscriminator: [UInt8] = [19, 45, 99, 29, 196, 50, 228, 117]

  /// `SingleSignerCollateral`: id, coordinator, authority_bump, name, nonce, owner.
  struct SingleSignerCollateral: Equatable {
    let coordinator: [UInt8]
    let nonce: UInt32
    let owner: [UInt8]
  }

  /// Parses a `SingleSignerCollateral` account, or `nil` when the discriminator doesn't match.
  static func parseSingleSigner(_ data: [UInt8]) -> SingleSignerCollateral? {
    guard data.count >= 8, Array(data[0..<8]) == singleSignerDiscriminator else { return nil }
    var reader = BorshReader(data: data, offset: 8)
    do {
      _ = try reader.pubkey()          // id
      let coordinator = try reader.pubkey()
      _ = try reader.u8()              // authority_bump — re-derived locally, this copy is unused
      _ = try reader.string()          // name
      let nonce = try reader.u32()
      let owner = try reader.pubkey()
      return SingleSignerCollateral(coordinator: coordinator, nonce: nonce, owner: owner)
    } catch {
      return nil
    }
  }

  /// `Coordinator`: id, bump, owner, collateral_creator, treasury, publishers, executors.
  static func parseCoordinatorExecutors(_ data: [UInt8]) throws -> [[UInt8]] {
    var reader = BorshReader(data: data, offset: 8)
    _ = try reader.pubkey()            // id
    _ = try reader.u8()                // bump
    _ = try reader.pubkey()            // owner
    _ = try reader.pubkey()            // collateral_creator
    _ = try reader.pubkey()            // treasury
    let publishers = try reader.u32()
    for _ in 0..<publishers { _ = try reader.pubkey() }
    let executors = try reader.u32()
    return try (0..<executors).map { _ in try reader.pubkey() }
  }

  /// Sequential little-endian borsh reader; throws on truncated data.
  private struct BorshReader {
    let data: [UInt8]
    var offset: Int

    mutating func u8() throws -> UInt8 {
      data[try next(1)]
    }

    mutating func u32() throws -> UInt32 {
      let start = try next(4)
      var value: UInt32 = 0
      for i in 0..<4 {
        value |= UInt32(truncatingIfNeeded: data[start + i]) << (8 * i)
      }
      return value
    }

    mutating func pubkey() throws -> [UInt8] {
      let start = try next(32)
      return Array(data[start..<(start + 32)])
    }

    mutating func string() throws -> String {
      let length = Int(try u32())
      guard length <= data.count else {
        throw RainError.internalError(details: "Implausible borsh string length: \(length)")
      }
      let start = try next(length)
      return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    private mutating func next(_ size: Int) throws -> Int {
      let start = offset
      guard size >= 0, start + size <= data.count else {
        throw RainError.internalError(
          details: "Truncated Solana account data at offset \(start)"
        )
      }
      offset += size
      return start
    }
  }
}
