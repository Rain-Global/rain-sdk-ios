import Foundation
import Web3

/// Builders for the instructions the SDK sends on Solana beyond a plain transfer.
///
/// Account order within each instruction is fixed by the target program's interface and must not
/// be rearranged — programs read their accounts positionally.
internal enum SolanaInstructions {
  /// `AssociatedTokenAccountInstruction::CreateIdempotent`. Preferred over `Create` (0), which
  /// fails if the account already exists.
  private static let ataCreateIdempotentIndex: UInt8 = 1

  /// In an ed25519 offsets struct, `u16::MAX` points the runtime at this same instruction.
  private static let ed25519ThisInstruction = 0xFFFF

  /// Anchor discriminator `sha256("global:withdraw_single_signer_collateral_asset")[0..8]`.
  private static let withdrawSingleSignerDiscriminator: [UInt8] = [13, 25, 64, 83, 111, 184, 70, 241]

  typealias Instruction = SolanaTransactionBuilder.Instruction
  typealias AccountMeta = SolanaTransactionBuilder.AccountMeta

  /// Creates `owner`'s associated token account for `mint`, or does nothing if it already exists.
  ///
  /// `payer` funds the account's rent-exempt balance, so on a withdrawal this is the wallet
  /// initiating it, not the recipient who ends up owning the account.
  static func createAssociatedTokenAccountIdempotent(
    tokenProgramId: String,
    payer: String,
    associatedAccount: String,
    owner: String,
    mint: String
  ) -> Instruction {
    Instruction(
      programId: SolanaPrograms.associatedTokenAccount,
      accounts: [
        .writable(payer, signer: true),
        .writable(associatedAccount),
        .readonly(owner),
        .readonly(mint),
        .readonly(SolanaPrograms.system),
        .readonly(tokenProgramId)
      ],
      data: [ataCreateIdempotentIndex]
    )
  }

  /// Native ed25519-program verification of a single `signature` by `signer` over `message`.
  ///
  /// Layout: count + padding, one 14-byte offsets struct (with `u16::MAX` as the instruction
  /// index, meaning "this instruction"), then pubkey ‖ signature ‖ message. The instruction has no
  /// accounts; programs read its result back through the instructions sysvar.
  static func ed25519Verify(
    signer: [UInt8],
    signature: [UInt8],
    message: [UInt8]
  ) throws -> Instruction {
    guard signer.count == 32 else {
      throw RainError.internalError(details: "ed25519 signer must be 32 bytes, got \(signer.count)")
    }
    guard signature.count == 64 else {
      throw RainError.internalError(details: "ed25519 signature must be 64 bytes, got \(signature.count)")
    }
    guard message.count == 32 else {
      throw RainError.internalError(details: "ed25519 message must be 32 bytes, got \(message.count)")
    }

    let pubkeyOffset = 2 + 14 // count + padding + one offsets struct
    let signatureOffset = pubkeyOffset + 32
    let messageOffset = signatureOffset + 64

    var data = [UInt8](repeating: 0, count: messageOffset + 32)
    data[0] = 1 // signature count
    writeU16LE(&data, offset: 2, value: signatureOffset)
    writeU16LE(&data, offset: 4, value: ed25519ThisInstruction)
    writeU16LE(&data, offset: 6, value: pubkeyOffset)
    writeU16LE(&data, offset: 8, value: ed25519ThisInstruction)
    writeU16LE(&data, offset: 10, value: messageOffset)
    writeU16LE(&data, offset: 12, value: message.count)
    writeU16LE(&data, offset: 14, value: ed25519ThisInstruction)
    data.replaceSubrange(pubkeyOffset..<(pubkeyOffset + 32), with: signer)
    data.replaceSubrange(signatureOffset..<(signatureOffset + 64), with: signature)
    data.replaceSubrange(messageOffset..<(messageOffset + 32), with: message)

    return Instruction(
      programId: SolanaPrograms.ed25519Verify,
      accounts: [],
      data: data
    )
  }

  /// Rain collateral program (v2.02): `withdraw_single_signer_collateral_asset`.
  ///
  /// Account order and the borsh-encoded request follow the program's Anchor IDL. `owner` both
  /// signs the transaction and pays the fee; the coordinator's authorization arrives via a
  /// preceding ``ed25519Verify`` instruction, and `coordinatorSignatureSalt` ties this request to
  /// that signature's domain.
  static func withdrawSingleSignerCollateralAsset(
    programId: String,
    owner: String,
    coordinator: String,
    collateral: String,
    collateralAuthority: String,
    destination: String,
    asset: String,
    collateralTokenAccount: String,
    destinationTokenAccount: String,
    tokenProgramId: String,
    amountBaseUnits: BigUInt,
    expiresAtEpochSeconds: Int64,
    coordinatorSignatureSalt: [UInt8]
  ) throws -> Instruction {
    guard let amount = UInt64(exactly: amountBaseUnits) else {
      throw RainError.invalidAmount(
        amount: amountBaseUnits.description,
        reason: "withdrawal amount is out of u64 range"
      )
    }
    guard coordinatorSignatureSalt.count == 32 else {
      throw RainError.internalError(
        details: "Coordinator signature salt must be 32 bytes, got \(coordinatorSignatureSalt.count)"
      )
    }

    // Borsh: discriminator ‖ WithdrawSingleSignerCollateralAssetRequest
    //   { amount_in_asset: u64, signature_expiration_time: i64, coordinator_signature_salt: [u8; 32] }
    var data = [UInt8](repeating: 0, count: 8 + 8 + 8 + 32)
    data.replaceSubrange(0..<8, with: withdrawSingleSignerDiscriminator)
    writeU64LE(&data, offset: 8, value: amount)
    writeU64LE(&data, offset: 16, value: UInt64(bitPattern: expiresAtEpochSeconds))
    data.replaceSubrange(24..<56, with: coordinatorSignatureSalt)

    return Instruction(
      programId: programId,
      accounts: [
        .writable(owner, signer: true),
        .readonly(coordinator),
        .writable(collateral),
        .writable(collateralAuthority),
        .writable(destination),
        .readonly(asset),
        .writable(collateralTokenAccount),
        .writable(destinationTokenAccount),
        .readonly(tokenProgramId),
        .readonly(SolanaPrograms.sysvarInstructions),
        .readonly(SolanaPrograms.system)
      ],
      data: data
    )
  }

  // MARK: - Little-endian writers

  private static func writeU16LE(_ target: inout [UInt8], offset: Int, value: Int) {
    target[offset] = UInt8(value & 0xFF)
    target[offset + 1] = UInt8((value >> 8) & 0xFF)
  }

  private static func writeU64LE(_ target: inout [UInt8], offset: Int, value: UInt64) {
    var v = value
    for i in 0..<8 {
      target[offset + i] = UInt8(truncatingIfNeeded: v)
      v >>= 8
    }
  }
}
