import Foundation

/// On-chain program addresses and instruction payloads the SDK builds transactions against.
///
/// Only what SPL transfers need: the two token programs (classic and Token-2022 — a mint declares
/// which one owns it), the Associated Token Account program, and the System Program the ATA
/// program needs to fund a new account.
internal enum SolanaPrograms {
  static let system = "11111111111111111111111111111111"
  static let splToken = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  static let token2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
  static let associatedTokenAccount = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
  /// Native ed25519 signature-verification program — proves an off-chain signature to a program
  /// that reads the result back through the instructions sysvar.
  static let ed25519Verify = "Ed25519SigVerify111111111111111111111111111"
  static let sysvarInstructions = "Sysvar1nstructions1111111111111111111111111"

  /// Whether `programId` is a token program the SDK can transfer through — the guard against
  /// treating an arbitrary account as a mint.
  static func isTokenProgram(_ programId: String) -> Bool {
    programId == splToken || programId == token2022
  }

  /// SPL Token `TransferChecked`: tag 12, u64 LE amount, u8 decimals.
  ///
  /// Preferred over the bare `Transfer` (tag 3) because the program verifies the decimals against
  /// the mint — a wrong client-side decimals value fails the transaction instead of moving the
  /// wrong amount.
  static func transferCheckedData(amount: UInt64, decimals: UInt8) -> [UInt8] {
    var data: [UInt8] = [12]
    var value = amount
    for _ in 0..<8 {
      data.append(UInt8(truncatingIfNeeded: value))
      value >>= 8
    }
    data.append(decimals)
    return data
  }

  /// Associated Token Account program `CreateIdempotent` (tag 1): creates the recipient's token
  /// account, or succeeds as a no-op when it already exists.
  static let createIdempotentData: [UInt8] = [1]
}
