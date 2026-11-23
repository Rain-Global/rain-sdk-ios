import CryptoKit
import Foundation
import Web3

/// Program-derived address (PDA) support — what SPL transfers need to know *where* a wallet's
/// token account lives.
///
/// A PDA is `sha256(seeds ‖ bump ‖ programId ‖ "ProgramDerivedAddress")` for the highest bump
/// (255 downwards) whose digest is **not** a valid ed25519 point. That off-curve requirement is
/// the whole point: an address nobody can hold a private key for, so only the owning program can
/// sign for it. Skipping the curve check would produce a wrong address about half the time, so
/// the ed25519 decompression math is implemented here rather than approximated.
///
/// Mirrors `curve25519-dalek`'s `CompressedEdwardsY::decompress` (what Solana's
/// `Pubkey::is_on_curve` uses), so derived addresses match the network's exactly.
internal enum SolanaProgramAddress {
  private static let publicKeyLength = 32
  /// Solana's cap: 16 seeds, each at most 32 bytes.
  private static let maxSeeds = 16
  private static let maxSeedLength = 32
  private static let pdaMarker = Array("ProgramDerivedAddress".utf8)

  // MARK: - Derivation

  /// The associated token account for `owner` / `mint` under `tokenProgramId`.
  ///
  /// The token program is a *seed*, so a Token-2022 mint derives a different account than a
  /// classic SPL mint for the same owner.
  static func associatedTokenAddress(
    owner: String,
    mint: String,
    tokenProgramId: String
  ) throws -> String {
    let seeds = [
      try decodeKey(owner, label: "owner"),
      try decodeKey(tokenProgramId, label: "token program"),
      try decodeKey(mint, label: "mint")
    ]
    let derived = try findProgramAddress(
      seeds: seeds,
      programId: try decodeKey(SolanaPrograms.associatedTokenAccount, label: "ATA program")
    )
    return Base58.encode(derived.address)
  }

  /// First off-curve address for `seeds` under `programId`, searching bumps 255 → 1 (the range
  /// `find_program_address` itself covers).
  static func findProgramAddress(
    seeds: [[UInt8]],
    programId: [UInt8]
  ) throws -> (address: [UInt8], bump: UInt8) {
    guard seeds.count < maxSeeds else {
      throw RainError.internalError(details: "Too many PDA seeds: \(seeds.count)")
    }
    for seed in seeds where seed.count > maxSeedLength {
      throw RainError.internalError(details: "PDA seed longer than \(maxSeedLength) bytes")
    }

    var bump = 255
    while bump >= 1 {
      var input: [UInt8] = seeds.flatMap { $0 }
      input.append(UInt8(bump))
      input.append(contentsOf: programId)
      input.append(contentsOf: pdaMarker)

      let digest = [UInt8](SHA256.hash(data: Data(input)))
      if !isOnCurve(digest) {
        return (digest, UInt8(bump))
      }
      bump -= 1
    }
    throw RainError.internalError(details: "No off-curve program address for the given seeds")
  }

  // MARK: - ed25519

  /// Field prime, 2^255 - 19.
  private static let p = BigUInt(2).power(255) - 19
  /// Curve constant d = -121665/121666 mod p.
  private static let d: BigUInt =
    "37095705934669439343138083508754565189542113879843219016388785533085940283555"
  /// (p - 5) / 8 = 2^252 - 3, the exponent in the candidate-root formula.
  private static let sqrtExponent = BigUInt(2).power(252) - 3

  /// Whether a 32-byte compressed point decompresses to a valid ed25519 point — i.e. whether the
  /// bytes could be somebody's public key. `false` means the bytes are a usable PDA.
  ///
  /// Decompression solves `x² = (y² - 1) / (d·y² + 1)`: compute the candidate root
  /// `x = u·v³·(u·v⁷)^((p-5)/8)`, then accept when `v·x² == ±u` (the negative branch being the
  /// root multiplied by sqrt(-1)).
  static func isOnCurve(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == publicKeyLength else { return false }

    // Little-endian y with the sign bit cleared, reduced mod p (matching dalek's field decode).
    var yBytes = bytes
    yBytes[publicKeyLength - 1] &= 0x7F
    let y = BigUInt(Data(yBytes.reversed())) % p

    let ySquared = (y * y) % p
    let u = (ySquared + p - 1) % p          // y² - 1
    let v = (d * ySquared + 1) % p          // d·y² + 1

    let v3 = (v * v % p) * v % p
    let v7 = (v3 * v3 % p) * v % p
    let candidate = (u * v3 % p) * (u * v7 % p).power(sqrtExponent, modulus: p) % p

    let check = v * candidate % p * candidate % p
    if check == u { return true }
    if check == (p - u) % p { return true }
    return false
  }

  // MARK: - Helpers

  private static func decodeKey(_ address: String, label: String) throws -> [UInt8] {
    let bytes: [UInt8]
    do {
      bytes = try Base58.decode(address)
    } catch {
      throw RainError.internalError(details: "Invalid Solana \(label) address: \(address)")
    }
    guard bytes.count == publicKeyLength else {
      throw RainError.internalError(
        details: "Invalid Solana \(label) address (expected 32 bytes, got \(bytes.count)): \(address)"
      )
    }
    return bytes
  }
}
