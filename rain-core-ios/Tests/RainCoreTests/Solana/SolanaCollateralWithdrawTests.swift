import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

/// The message-encoding golden test uses values captured from a LIVE Rain dev-API withdrawal
/// signature (2026-07-24, devnet collateral `2h5mCX…`): the expected message is the exact
/// 32-byte payload that the coordinator executor's real ed25519 signature verified against.
/// If the encoding drifts in any byte, on-chain verification would fail — this pins it.
///
/// Byte-exact vectors for the withdraw instruction encoding.
@Suite("Solana Withdraw Messages Tests")
struct SolanaWithdrawMessagesTests {

  @Test("coordinator withdraw message matches live-verified vector")
  func testCoordinatorWithdrawMessageGoldenVector() throws {
    let message = SolanaWithdrawMessages.coordinatorWithdrawMessage(
      coordinator: try Base58.decode("FF3tTZ91aRu7XdGc4XK6V7MkDyStJ5ZY2fG4ZKLqFgL5"),
      collateral: try Base58.decode("2h5mCXyirbPJZbjGcWf4PTpcA6M7qZ5UCRaWysHjnx31"),
      sender: try Base58.decode("3mhBCgFYhFCAV7LFARCcLuLsQLsyErTRc2axkGJrf8UG"),
      receiver: try Base58.decode("3mhBCgFYhFCAV7LFARCcLuLsQLsyErTRc2axkGJrf8UG"),
      asset: try Base58.decode("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"),
      amountBaseUnits: 1,
      nonce: 0,
      expiresAtEpochSeconds: 1_784_912_091,
      salt: [UInt8](Data(base64Encoded: "TQQ0CmdE6fdJzi6aFl6X68AKTETgYWKmPuoKvWpBb5w=")!)
    )

    #expect(
      SolanaTransactionBuilder.hexEncode(message)
        == "77229dff3a1aca1bf472323ba0cdf247669970593ab8f64b31d7e1e74d28e8f4"
    )
  }
}

@Suite("Solana ed25519 / Withdraw Instruction Tests")
struct SolanaEd25519InstructionTests {

  @Test("ed25519 verify instruction lays out offsets, pubkey, signature and message")
  func testEd25519VerifyLayout() throws {
    let signer = [UInt8](repeating: 0x11, count: 32)
    let signature = [UInt8](repeating: 0x22, count: 64)
    let message = [UInt8](repeating: 0x33, count: 32)

    let instruction = try SolanaInstructions.ed25519Verify(
      signer: signer,
      signature: signature,
      message: message
    )

    #expect(instruction.programId == "Ed25519SigVerify111111111111111111111111111")
    #expect(instruction.accounts.isEmpty)

    let data = instruction.data
    #expect(data.count == 144)
    #expect(data[0] == 1) // one signature
    #expect(data[1] == 0) // padding
    #expect(readU16LE(data, 2) == 48)     // signature offset
    #expect(readU16LE(data, 4) == 0xFFFF)
    #expect(readU16LE(data, 6) == 16)     // pubkey offset
    #expect(readU16LE(data, 8) == 0xFFFF)
    #expect(readU16LE(data, 10) == 112)   // message offset
    #expect(readU16LE(data, 12) == 32)    // message size
    #expect(readU16LE(data, 14) == 0xFFFF)
    #expect(Array(data[16..<48]) == signer)
    #expect(Array(data[48..<112]) == signature)
    #expect(Array(data[112..<144]) == message)
  }

  @Test("withdraw instruction encodes discriminator and borsh request")
  func testWithdrawInstructionEncoding() throws {
    let programId = Base58.encode([UInt8](repeating: 0x01, count: 32))
    let salt = [UInt8](repeating: 0x44, count: 32)

    let instruction = try SolanaInstructions.withdrawSingleSignerCollateralAsset(
      programId: programId,
      owner: Base58.encode([UInt8](repeating: 0x02, count: 32)),
      coordinator: Base58.encode([UInt8](repeating: 0x03, count: 32)),
      collateral: Base58.encode([UInt8](repeating: 0x04, count: 32)),
      collateralAuthority: Base58.encode([UInt8](repeating: 0x05, count: 32)),
      destination: Base58.encode([UInt8](repeating: 0x06, count: 32)),
      asset: Base58.encode([UInt8](repeating: 0x07, count: 32)),
      collateralTokenAccount: Base58.encode([UInt8](repeating: 0x08, count: 32)),
      destinationTokenAccount: Base58.encode([UInt8](repeating: 0x09, count: 32)),
      tokenProgramId: SolanaPrograms.splToken,
      amountBaseUnits: 10_000,
      expiresAtEpochSeconds: 1_784_912_091,
      coordinatorSignatureSalt: salt
    )

    #expect(instruction.programId == programId)

    let data = instruction.data
    #expect(data.count == 56)
    // Anchor discriminator for withdraw_single_signer_collateral_asset (from the IDL).
    #expect(Array(data[0..<8]) == [13, 25, 64, 83, 111, 184, 70, 241])
    #expect(readU64LE(data, 8) == 10_000)
    #expect(readU64LE(data, 16) == 1_784_912_091)
    #expect(Array(data[24..<56]) == salt)

    // Account order is the program's ABI — owner signs and pays, sysvars close the list.
    #expect(instruction.accounts.count == 11)
    #expect(instruction.accounts[0].isSigner)
    #expect(instruction.accounts[0].isWritable)
    #expect(instruction.accounts[9].pubkey == "Sysvar1nstructions1111111111111111111111111")
    #expect(instruction.accounts[10].pubkey == "11111111111111111111111111111111")
  }

  private func readU16LE(_ data: [UInt8], _ offset: Int) -> Int {
    Int(data[offset]) | (Int(data[offset + 1]) << 8)
  }

  private func readU64LE(_ data: [UInt8], _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
      value |= UInt64(truncatingIfNeeded: data[offset + i]) << (8 * i)
    }
    return value
  }
}

@Suite("Solana Collateral Account Tests")
struct SolanaCollateralAccountsTests {

  @Test("parses a single-signer collateral account")
  func testParseSingleSigner() throws {
    // Field values from the real devnet account at 2h5mCX… (name "CollateralSolana").
    let coordinator = try Base58.decode("FF3tTZ91aRu7XdGc4XK6V7MkDyStJ5ZY2fG4ZKLqFgL5")
    let owner = try Base58.decode("3mhBCgFYhFCAV7LFARCcLuLsQLsyErTRc2axkGJrf8UG")
    let name = Array("CollateralSolana".utf8)
    var data: [UInt8] = [19, 45, 99, 29, 196, 50, 228, 117] // discriminator
    data += [UInt8](repeating: 0x0A, count: 32)             // id
    data += coordinator
    data += [255]                                            // authority bump
    data += [UInt8(name.count), 0, 0, 0] + name              // borsh string
    data += [7, 0, 0, 0]                                     // nonce = 7, u32 LE
    data += owner

    let parsed = try #require(SolanaCollateralAccounts.parseSingleSigner(data))

    #expect(parsed.coordinator == coordinator)
    #expect(parsed.nonce == 7)
    #expect(parsed.owner == owner)
  }

  @Test("rejects an account with a different discriminator")
  func testRejectsWrongDiscriminator() {
    let data = [UInt8](repeating: 0x01, count: 120)
    #expect(SolanaCollateralAccounts.parseSingleSigner(data) == nil)
  }

  @Test("parses coordinator executors after variable-length publishers")
  func testParseCoordinatorExecutors() throws {
    let publisher = [UInt8](repeating: 0x0B, count: 32)
    let executor1 = [UInt8](repeating: 0x0C, count: 32)
    let executor2 = [UInt8](repeating: 0x0D, count: 32)
    var data = [UInt8](repeating: 0, count: 8)      // discriminator (not checked here)
    data += [UInt8](repeating: 0, count: 32)        // id
    data += [254]                                   // bump
    data += [UInt8](repeating: 0, count: 32)        // owner
    data += [UInt8](repeating: 0, count: 32)        // collateral_creator
    data += [UInt8](repeating: 0, count: 32)        // treasury
    data += [1, 0, 0, 0] + publisher
    data += [2, 0, 0, 0] + executor1 + executor2

    let executors = try SolanaCollateralAccounts.parseCoordinatorExecutors(data)

    #expect(executors.count == 2)
    #expect(executors[0] == executor1)
    #expect(executors[1] == executor2)
  }
}
