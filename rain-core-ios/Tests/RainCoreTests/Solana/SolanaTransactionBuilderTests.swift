import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

/// Pins the exact byte layout of the unsigned legacy transfer transaction handed to Turnkey,
/// matching `@solana/web3.js` `Transaction.serialize({ requireAllSignatures: false })`.
@Suite("SolanaTransactionBuilder")
struct SolanaTransactionBuilderTests {
  let fromBytes = (0..<32).map { UInt8($0 + 1) }
  let toBytes = (0..<32).map { UInt8($0 + 33) }
  let blockhashBytes = (0..<32).map { UInt8($0 + 65) }
  var from: String { Base58.encode(fromBytes) }
  var to: String { Base58.encode(toBytes) }
  var blockhash: String { Base58.encode(blockhashBytes) }

  @Test("compactU16 encodes small and multi-byte lengths")
  func compactU16() {
    #expect(SolanaTransactionBuilder.compactU16(0) == [0])
    #expect(SolanaTransactionBuilder.compactU16(1) == [1])
    #expect(SolanaTransactionBuilder.compactU16(127) == [127])
    #expect(SolanaTransactionBuilder.compactU16(128) == [0x80, 0x01])
  }

  @Test("serialized transfer has the exact expected layout")
  func exactLayout() throws {
    let tx = try SolanaTransactionBuilder.buildTransferBytes(
      from: from, to: to, lamports: 1_000_000_000, recentBlockhash: blockhash)
    var i = 0
    #expect(tx[i] == 1); i += 1
    #expect(Array(tx[i..<i+64]) == [UInt8](repeating: 0, count: 64)); i += 64
    #expect(tx[i] == 1); i += 1
    #expect(tx[i] == 0); i += 1
    #expect(tx[i] == 1); i += 1
    #expect(tx[i] == 3); i += 1
    #expect(Array(tx[i..<i+32]) == fromBytes); i += 32
    #expect(Array(tx[i..<i+32]) == toBytes); i += 32
    #expect(Array(tx[i..<i+32]) == [UInt8](repeating: 0, count: 32)); i += 32
    #expect(Array(tx[i..<i+32]) == blockhashBytes); i += 32
    #expect(tx[i] == 1); i += 1
    #expect(tx[i] == 2); i += 1
    #expect(tx[i] == 2); i += 1
    #expect(tx[i] == 0); i += 1
    #expect(tx[i] == 1); i += 1
    #expect(tx[i] == 12); i += 1
    #expect(Array(tx[i..<i+4]) == [2, 0, 0, 0]); i += 4
    #expect(Array(tx[i..<i+8]) == [0x00, 0xCA, 0x9A, 0x3B, 0, 0, 0, 0]); i += 8
    #expect(i == tx.count)
    #expect(tx.count == 215)
  }

  @Test("rejects a transaction requiring a signer besides the fee payer")
  func rejectsExtraRequiredSigner() throws {
    // A second required signer can never be satisfied: only the fee payer's key signs.
    let extraSigner = Base58.encode((0..<32).map { UInt8($0 + 97) })
    let instruction = SolanaTransactionBuilder.Instruction(
      programId: Base58.encode([UInt8](repeating: 0, count: 32)),
      accounts: [
        .writable(from, signer: true),
        .writable(extraSigner, signer: true),
        .writable(to)
      ],
      data: []
    )

    #expect(throws: RainError.invalidConfig(details: "Transaction requires 1 signer(s) besides the fee payer")) {
      _ = try SolanaTransactionBuilder.buildTransactionBytes(
        feePayer: from,
        recentBlockhash: blockhash,
        instructions: [instruction]
      )
    }
  }

  @Test("buildTransferHex emits lowercase hex of the serialized bytes")
  func hexMatchesBytes() throws {
    let bytes = try SolanaTransactionBuilder.buildTransferBytes(
      from: from, to: to, lamports: 1_000_000_000, recentBlockhash: blockhash)
    let hex = try SolanaTransactionBuilder.buildTransferHex(
      from: from, to: to, lamports: 1_000_000_000, recentBlockhash: blockhash)
    let expected = bytes.map { String(format: "%02x", $0) }.joined()
    #expect(hex == expected)
    #expect(hex.allSatisfy { "0123456789abcdef".contains($0) })
  }

  @Test("rejects non-32-byte addresses")
  func rejectsBadAddress() {
    let tooShort = Base58.encode([UInt8](repeating: 0, count: 31))
    #expect(throws: RainError.self) {
      _ = try SolanaTransactionBuilder.buildTransferHex(
        from: tooShort, to: to, lamports: 1, recentBlockhash: blockhash)
    }
  }
}

/// Byte-for-byte parity with the canonical Rust builder: the expected hex below is what
/// `solders` (`solana-program`'s `Message` / `Transaction::new_unsigned`) produces for the same
/// instructions, so account ordering, header and instruction indices are all pinned.
@Suite("SolanaTransactionBuilder SPL")
struct SolanaTransactionBuilderSPLTests {
  static let owner = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  static let recipient = "4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS"
  static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  static let source = "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B"
  static let destination = "DJcjpsHnWXSucjUpourygEN3mkcQwSHG6d5b2AzLSfSn"
  static let blockhash = "5Pk716N113awdSaUDZEPZVi9Zs6hJmG5KCJtp5qQK3LB"

  private func build(createDestination: Bool) throws -> String {
    try SolanaTransactionBuilder.buildSPLTransferHex(
      owner: Self.owner,
      source: Self.source,
      destination: Self.destination,
      destinationOwner: Self.recipient,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.splToken,
      amount: 1_500_000,
      decimals: 6,
      recentBlockhash: Self.blockhash,
      createDestinationAccount: createDestination
    )
  }

  @Test("a transfer into an existing token account is one TransferChecked instruction")
  func transferOnly() throws {
    let actual = try build(createDestination: false)
    #expect(actual == """
      0100000000000000000000000000000000000000000000000000000000000000000000000000000000000000\
      000000000000000000000000000000000000000000010002057e8c088760bfde1dddcf32c17f209b8242ee52\
      aaf131facd88d0ea2c6d0b06f2d3ea8cf5acaca8cd05207512175c43cef54a5dd99ede20a16b55253738f397\
      dcb6cf86c040eaa718bcca6c81c5e6de2d9268577c8dd1bf41607975c62e9684a7c6fa7af3bedbad3a3d65f3\
      6aabc97431b1bbe4c2d2f6e0e47ca60203452f5d6106ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37\
      913a8cf5857eff00a94142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60010404\
      010302000a0c60e316000000000006
      """)
  }

  @Test("a recipient with no token account gets an idempotent create first")
  func createThenTransfer() throws {
    let actual = try build(createDestination: true)
    #expect(actual == """
      0100000000000000000000000000000000000000000000000000000000000000000000000000000000000000\
      000000000000000000000000000000000000000000010005087e8c088760bfde1dddcf32c17f209b8242ee52\
      aaf131facd88d0ea2c6d0b06f2b6cf86c040eaa718bcca6c81c5e6de2d9268577c8dd1bf41607975c62e9684\
      a7d3ea8cf5acaca8cd05207512175c43cef54a5dd99ede20a16b55253738f397dc3b6a27bcceb6a42d62a3a8\
      d02a6f0d73653215771de243a63ac048a18b59da29c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0\
      e47ca60203452f5d6100000000000000000000000000000000000000000000000000000000000000008c9725\
      8f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f85906ddf6e1d765a193d9cbe146ceeb79\
      ac1cb485ed5f5b37913a8cf5857eff00a94142434445464748494a4b4c4d4e4f505152535455565758595a5b\
      5c5d5e5f6002060600010304050701010704020401000a0c60e316000000000006
      """)
  }

  @Test("a sponsored transfer carries the System Program as an extra read-only key, placed last")
  func sponsoredTransferCarriesSystemProgram() throws {
    let plain = try SolanaTransactionBuilder.buildSPLTransferBytes(
      owner: Self.owner, source: Self.source, destination: Self.destination,
      destinationOwner: Self.recipient, mint: Self.mint, tokenProgramId: SolanaPrograms.splToken,
      amount: 1_500_000, decimals: 6, recentBlockhash: Self.blockhash,
      createDestinationAccount: false
    )
    let sponsored = try SolanaTransactionBuilder.buildSPLTransferBytes(
      owner: Self.owner, source: Self.source, destination: Self.destination,
      destinationOwner: Self.recipient, mint: Self.mint, tokenProgramId: SolanaPrograms.splToken,
      amount: 1_500_000, decimals: 6, recentBlockhash: Self.blockhash,
      createDestinationAccount: false,
      extraReadonlyKeys: [SolanaPrograms.system]
    )

    // Header (after the 1 + 64 byte signature section): required signers, readonly signed,
    // readonly unsigned, then the compact-u16 key count.
    let header = 65
    #expect(plain[header + 2] == 2 && plain[header + 3] == 5)
    #expect(sponsored[header + 2] == 3 && sponsored[header + 3] == 6)
    // The extra key is the last static key, and the message is exactly one key longer.
    let sponsoredLastKey = Array(sponsored[(header + 4 + 5 * 32)..<(header + 4 + 6 * 32)])
    #expect(sponsoredLastKey == [UInt8](repeating: 0, count: 32))
    #expect(sponsored.count == plain.count + 32)
  }

  @Test("an extra key already in the table is not repeated")
  func extraKeyDeduplicated() throws {
    // The create-account instruction already references the System Program.
    let plain = try SolanaTransactionBuilder.buildSPLTransferBytes(
      owner: Self.owner, source: Self.source, destination: Self.destination,
      destinationOwner: Self.recipient, mint: Self.mint, tokenProgramId: SolanaPrograms.splToken,
      amount: 1_500_000, decimals: 6, recentBlockhash: Self.blockhash,
      createDestinationAccount: true
    )
    let sponsored = try SolanaTransactionBuilder.buildSPLTransferBytes(
      owner: Self.owner, source: Self.source, destination: Self.destination,
      destinationOwner: Self.recipient, mint: Self.mint, tokenProgramId: SolanaPrograms.splToken,
      amount: 1_500_000, decimals: 6, recentBlockhash: Self.blockhash,
      createDestinationAccount: true,
      extraReadonlyKeys: [SolanaPrograms.system]
    )
    #expect(sponsored == plain)
  }

  @Test("TransferChecked data is the tag, u64 amount and decimals")
  func instructionData() {
    #expect(
      SolanaPrograms.transferCheckedData(amount: 1_500_000, decimals: 6)
        == [12, 0x60, 0xE3, 0x16, 0, 0, 0, 0, 0, 6]
    )
  }

  @Test("rejects a malformed mint before serializing")
  func rejectsBadMint() {
    #expect(throws: RainError.self) {
      _ = try SolanaTransactionBuilder.buildSPLTransferHex(
        owner: Self.owner,
        source: Self.source,
        destination: Self.destination,
        destinationOwner: Self.recipient,
        mint: "not-a-mint!",
        tokenProgramId: SolanaPrograms.splToken,
        amount: 1,
        decimals: 6,
        recentBlockhash: Self.blockhash,
        createDestinationAccount: false
      )
    }
  }
}
