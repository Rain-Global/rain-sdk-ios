import Foundation

/// Minimal decoder for the unsigned legacy Solana transactions produced by
/// `SolanaTransactionBuilder`. Turnkey's `sol_send_transaction` activity stores only the
/// unsigned transaction — no recipient or amount — so transaction history recovers what it shows
/// (System transfers and SPL token transfers) by parsing that blob.
///
/// Reverses the builder's wire format: compact-u16 signature count + zero-filled signatures +
/// message (header, account keys, blockhash, instructions). Returns `nil` if the bytes aren't a
/// decodable transaction containing the transfer being looked for.
@_spi(RainAdapter) public enum SolanaTransactionDecoder {
  private static let publicKeyLength = 32
  private static let signatureLength = 64
  private static let systemProgramId = [UInt8](repeating: 0, count: 32)
  private static let systemTransferInstructionIndex: UInt64 = 2
  /// SPL Token instruction tags.
  private static let tokenTransferTag: UInt8 = 3
  private static let tokenTransferCheckedTag: UInt8 = 12
  /// Associated Token Account program tags that create an account (`Create` / `CreateIdempotent`).
  private static let ataCreateTags: Set<UInt8> = [0, 1]

  @_spi(RainAdapter) public struct Transfer: Equatable, Sendable {
    public let from: String
    public let to: String
    public let lamports: UInt64
  }

  /// An SPL token transfer recovered from an unsigned transaction.
  ///
  /// `destination` is a *token account*, not a wallet: only a transaction that also creates that
  /// account carries its owner, so `destinationOwner` is `nil` otherwise and the caller resolves
  /// it (or displays the token account). `decimals` and `mint` are `nil` for the bare `Transfer`
  /// instruction, which carries neither.
  @_spi(RainAdapter) public struct TokenTransfer: Equatable, Sendable {
    public let owner: String
    public let source: String
    public let destination: String
    public let destinationOwner: String?
    public let mint: String?
    public let rawAmount: UInt64
    public let decimals: UInt8?
  }

  /// Decodes the unsigned transaction (hex, or base64 as a fallback). Returns `nil` on any
  /// parse failure or if the transaction isn't a System transfer.
  @_spi(RainAdapter) public static func decodeTransfer(_ unsignedTransaction: String) -> Transfer? {
    guard let message = decodeMessage(unsignedTransaction) else { return nil }

    for instruction in message.instructions {
      guard message.programId(of: instruction) == systemProgramId,
            instruction.data.count >= 12,
            readU32LE(instruction.data, offset: 0) == systemTransferInstructionIndex else {
        continue
      }
      guard let from = message.account(instruction, at: 0),
            let to = message.account(instruction, at: 1) else {
        return nil
      }
      return Transfer(from: from, to: to, lamports: readU64LE(instruction.data, offset: 4))
    }
    return nil
  }

  /// Decodes an SPL token transfer (`TransferChecked`, or the bare `Transfer`) out of the same
  /// blob. Returns `nil` when the transaction carries neither.
  @_spi(RainAdapter) public static func decodeTokenTransfer(_ unsignedTransaction: String) -> TokenTransfer? {
    guard let message = decodeMessage(unsignedTransaction) else { return nil }

    let tokenPrograms = [SolanaPrograms.splToken, SolanaPrograms.token2022]
      .compactMap { try? Base58.decode($0) }

    for instruction in message.instructions {
      guard let programId = message.programId(of: instruction),
            tokenPrograms.contains(programId),
            let tag = instruction.data.first else {
        continue
      }

      // TransferChecked: [source, mint, destination, owner], data = tag + u64 amount + u8 decimals.
      // Transfer:        [source, destination, owner],       data = tag + u64 amount.
      let checked = tag == tokenTransferCheckedTag
      guard checked || tag == tokenTransferTag,
            instruction.data.count >= (checked ? 10 : 9),
            let source = message.account(instruction, at: 0),
            let destination = message.account(instruction, at: checked ? 2 : 1),
            let owner = message.account(instruction, at: checked ? 3 : 2) else {
        continue
      }

      return TokenTransfer(
        owner: owner,
        source: source,
        destination: destination,
        destinationOwner: ataOwner(of: destination, in: message),
        mint: checked ? message.account(instruction, at: 1) : nil,
        rawAmount: readU64LE(instruction.data, offset: 1),
        decimals: checked ? instruction.data[9] : nil
      )
    }
    return nil
  }

  /// The wallet an Associated Token Account program instruction in this transaction creates
  /// `tokenAccount` for — the one place a transfer's recipient wallet appears on the wire.
  private static func ataOwner(of tokenAccount: String, in message: DecodedMessage) -> String? {
    guard let ataProgram = try? Base58.decode(SolanaPrograms.associatedTokenAccount) else {
      return nil
    }
    for instruction in message.instructions {
      guard message.programId(of: instruction) == ataProgram,
            let tag = instruction.data.first, ataCreateTags.contains(tag),
            // [payer, ata, owner, mint, systemProgram, tokenProgram]
            message.account(instruction, at: 1) == tokenAccount else {
        continue
      }
      return message.account(instruction, at: 2)
    }
    return nil
  }

  // MARK: - Message decoding

  private struct DecodedInstruction {
    let programIdIndex: Int
    let accountIndices: [Int]
    let data: [UInt8]
  }

  private struct DecodedMessage {
    let accounts: [[UInt8]]
    let instructions: [DecodedInstruction]

    func programId(of instruction: DecodedInstruction) -> [UInt8]? {
      accounts.indices.contains(instruction.programIdIndex) ? accounts[instruction.programIdIndex] : nil
    }

    /// The base58 key an instruction references at `position` in its own account list.
    func account(_ instruction: DecodedInstruction, at position: Int) -> String? {
      guard instruction.accountIndices.indices.contains(position) else { return nil }
      let index = instruction.accountIndices[position]
      guard accounts.indices.contains(index) else { return nil }
      return Base58.encode(accounts[index])
    }
  }

  private static func decodeMessage(_ unsignedTransaction: String) -> DecodedMessage? {
    guard let bytes = hexToBytes(unsignedTransaction) ?? base64ToBytes(unsignedTransaction) else {
      return nil
    }
    return try? parse(bytes)
  }

  private static func parse(_ bytes: [UInt8]) throws -> DecodedMessage {
    let reader = Reader(bytes)

    // Signature section: count + count * 64-byte placeholders.
    let signatureCount = try reader.readCompactU16()
    try reader.skip(signatureCount * signatureLength)

    // Message header (3 bytes), unused here.
    _ = try reader.readByte()
    _ = try reader.readByte()
    _ = try reader.readByte()

    // Account keys.
    let accountCount = try reader.readCompactU16()
    var accounts: [[UInt8]] = []
    accounts.reserveCapacity(accountCount)
    for _ in 0..<accountCount { accounts.append(try reader.readBytes(publicKeyLength)) }

    // Recent blockhash.
    try reader.skip(publicKeyLength)

    let instructionCount = try reader.readCompactU16()
    var instructions: [DecodedInstruction] = []
    instructions.reserveCapacity(instructionCount)
    for _ in 0..<instructionCount {
      let programIdIndex = try reader.readByte()
      let accountIndexCount = try reader.readCompactU16()
      var accountIndices: [Int] = []
      accountIndices.reserveCapacity(accountIndexCount)
      for _ in 0..<accountIndexCount { accountIndices.append(try reader.readByte()) }
      let dataLen = try reader.readCompactU16()
      instructions.append(
        DecodedInstruction(
          programIdIndex: programIdIndex,
          accountIndices: accountIndices,
          data: try reader.readBytes(dataLen)
        )
      )
    }

    return DecodedMessage(accounts: accounts, instructions: instructions)
  }

  private final class Reader {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func readByte() throws -> Int {
      guard pos < bytes.count else {
        throw RainError.internalError(details: "Unexpected end of transaction")
      }
      defer { pos += 1 }
      return Int(bytes[pos])
    }

    func readBytes(_ length: Int) throws -> [UInt8] {
      guard pos + length <= bytes.count else {
        throw RainError.internalError(details: "Unexpected end of transaction")
      }
      defer { pos += length }
      return Array(bytes[pos..<pos + length])
    }

    func skip(_ length: Int) throws {
      guard pos + length <= bytes.count else {
        throw RainError.internalError(details: "Unexpected end of transaction")
      }
      pos += length
    }

    /// Solana short-vec (compact-u16): 7 bits per byte, MSB = continuation.
    func readCompactU16() throws -> Int {
      var result = 0
      var shift = 0
      while true {
        let b = try readByte()
        result |= (b & 0x7F) << shift
        if b & 0x80 == 0 { break }
        shift += 7
      }
      return result
    }
  }

  private static func readU32LE(_ data: [UInt8], offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<4 {
      let byte = UInt64(truncatingIfNeeded: data[offset + i])
      value |= byte << (i * 8)
    }
    return value
  }

  private static func readU64LE(_ data: [UInt8], offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
      let byte = UInt64(truncatingIfNeeded: data[offset + i])
      value |= byte << (i * 8)
    }
    return value
  }

  private static func hexToBytes(_ hex: String) -> [UInt8]? {
    let clean = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
    guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(clean.count / 2)
    var index = clean.startIndex
    while index < clean.endIndex {
      let next = clean.index(index, offsetBy: 2)
      guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
      out.append(byte)
      index = next
    }
    return out
  }

  private static func base64ToBytes(_ string: String) -> [UInt8]? {
    guard let data = Data(base64Encoded: string), !data.isEmpty else { return nil }
    return [UInt8](data)
  }
}
