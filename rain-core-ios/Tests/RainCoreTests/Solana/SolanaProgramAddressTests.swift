import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

/// Pins the PDA / associated-token-account derivation against vectors produced by the canonical
/// Rust implementation (`solders`, which wraps `solana-program`'s `Pubkey::find_program_address`
/// and `is_on_curve`). Getting the ed25519 curve check wrong silently yields a *different*
/// address roughly half the time, so these are exact-match assertions, not smoke tests.
@Suite("SolanaProgramAddress")
struct SolanaProgramAddressTests {
  // A real wallet / mint pair; both are ordinary ed25519 public keys.
  static let owner = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

  @Test("associated token address matches the canonical derivation")
  func classicTokenProgram() throws {
    let ata = try SolanaProgramAddress.associatedTokenAddress(
      owner: Self.owner,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.splToken
    )
    #expect(ata == "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B")
  }

  @Test("a Token-2022 mint derives a different associated account")
  func token2022Program() throws {
    let ata = try SolanaProgramAddress.associatedTokenAddress(
      owner: Self.owner,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.token2022
    )
    #expect(ata == "GdjpegrtGwU3pgtzPivYVViSA8rmGL248qBVKzsrU3DD")
  }

  @Test("findProgramAddress returns the canonical bump")
  func canonicalBump() throws {
    let derived = try SolanaProgramAddress.findProgramAddress(
      seeds: [
        try Base58.decode(Self.owner),
        try Base58.decode(SolanaPrograms.splToken),
        try Base58.decode(Self.mint)
      ],
      programId: try Base58.decode(SolanaPrograms.associatedTokenAccount)
    )
    #expect(derived.bump == 254)
    #expect(Base58.encode(derived.address) == "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B")
  }

  @Test("real public keys are on the curve")
  func onCurveKeys() throws {
    let keys = [
      "4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS",
      "AKnL4NNf3DGWZJS6cPknBuEGnVsV4A4m5tgebLHaRSZ9",
      "9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu",
      "GyGKxMyg1p9SsHfm15MkNUu1u9TN2JtTspcdmrtGUdse",
      "EdmxWPmx2WH6WgFfTdu9xfkYf3k1g5wD1zccTVySEEh1",
      owner,
      mint,
      // The System Program's all-zero key happens to be a valid curve point.
      SolanaPrograms.system
    ]
    for key in keys {
      #expect(SolanaProgramAddress.isOnCurve(try Base58.decode(key)), "expected on curve: \(key)")
    }
  }

  @Test("program-derived addresses are off the curve")
  func offCurveKeys() throws {
    let keys = [
      "7C2K6QRDFeFnic4EYdiwgr3qAH6UJApix4tD7vPJBpbH",
      "A95iejEv6tzT8GHNrqfykRjqgdJmyRVRsf9dCU94kzRh",
      "5u4hwev6ix8qj5TjPpwpSizYuPLtQhQT1mA3MjVJM7qA",
      "3JwwaFbQcMFMTLDcprvtBVa6Zr6nGq1k74ZE8X9a8Z3N",
      "QNCGDW1kg7NpgCC1RMv7HJUXcufKAAgWHAwAWmDhJAk",
      "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B"
    ]
    for key in keys {
      #expect(!SolanaProgramAddress.isOnCurve(try Base58.decode(key)), "expected off curve: \(key)")
    }
  }

  @Test("a malformed address is rejected before derivation")
  func rejectsBadAddress() {
    #expect(throws: RainError.self) {
      _ = try SolanaProgramAddress.associatedTokenAddress(
        owner: "not-base58!",
        mint: Self.mint,
        tokenProgramId: SolanaPrograms.splToken
      )
    }
    #expect(throws: RainError.self) {
      _ = try SolanaProgramAddress.associatedTokenAddress(
        owner: Base58.encode([UInt8](repeating: 7, count: 31)),
        mint: Self.mint,
        tokenProgramId: SolanaPrograms.splToken
      )
    }
  }

  // Instance-scoped aliases so the assertions above read cleanly.
  var owner: String { Self.owner }
  var mint: String { Self.mint }
}
