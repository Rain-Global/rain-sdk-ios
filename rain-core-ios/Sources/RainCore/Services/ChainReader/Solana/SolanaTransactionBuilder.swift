import Foundation

/// Builds the **unsigned** Solana transaction that Turnkey's `sol_send_transaction` activity
/// expects (it decodes and parses the unsigned payload, signs it with the wallet's ed25519
/// key, and broadcasts).
///
/// NOTE on encoding: the Turnkey Swift type documents `unsignedTransaction` as "base64", but
/// the live API hex-decodes the field, so the adapter sends `serializedHex` by default. Both
/// `serializedHex` and `serializedBase64` are exposed so flipping the encoding is one line.
///
/// The wire format matches `@solana/web3.js` `Transaction.serialize({ requireAllSignatures:
/// false })`: a legacy transaction = compact-u16 signature count + one zero-filled 64-byte
/// signature placeholder + the serialized message. Turnkey fills the placeholder with the real
/// signature.
///
/// Two shapes are built: a native SOL transfer (System Program `transfer`) and an SPL token
/// transfer (`TransferChecked`, optionally preceded by an idempotent ATA creation) — both through
/// the same generic ``buildTransactionBytes(feePayer:recentBlockhash:instructions:)``.
///
/// Pure and dependency-free so it can be unit-tested byte-for-byte.
internal enum SolanaTransactionBuilder {
  private static let publicKeyLength = 32
  private static let signatureLength = 64
  private static let systemProgramId = [UInt8](repeating: 0, count: 32) // all-zero account = 1111…1111
  private static let systemTransferInstructionIndex: UInt32 = 2 // SystemInstruction::Transfer

  /// One account reference inside an instruction. The same account may appear in several
  /// instructions with different flags; the message merges them.
  struct AccountMeta {
    let pubkey: String
    let isSigner: Bool
    let isWritable: Bool

    static func writable(_ pubkey: String, signer: Bool = false) -> AccountMeta {
      AccountMeta(pubkey: pubkey, isSigner: signer, isWritable: true)
    }

    static func readonly(_ pubkey: String, signer: Bool = false) -> AccountMeta {
      AccountMeta(pubkey: pubkey, isSigner: signer, isWritable: false)
    }
  }

  struct Instruction {
    let programId: String
    let accounts: [AccountMeta]
    let data: [UInt8]
  }

  /// Lowercase hex of the serialized unsigned transaction.
  static func buildTransferHex(
    from fromAddress: String,
    to toAddress: String,
    lamports: UInt64,
    recentBlockhash: String
  ) throws -> String {
    toHex(try buildTransferBytes(from: fromAddress, to: toAddress, lamports: lamports, recentBlockhash: recentBlockhash))
  }

  /// Base64 of the serialized unsigned transaction (per the Turnkey type's documented encoding).
  static func buildTransferBase64(
    from fromAddress: String,
    to toAddress: String,
    lamports: UInt64,
    recentBlockhash: String
  ) throws -> String {
    Data(try buildTransferBytes(from: fromAddress, to: toAddress, lamports: lamports, recentBlockhash: recentBlockhash)).base64EncodedString()
  }

  static func buildTransferBytes(
    from fromAddress: String,
    to toAddress: String,
    lamports: UInt64,
    recentBlockhash: String
  ) throws -> [UInt8] {
    // Account ordering works out to [from, to, systemProgram] — the historical layout.
    try buildTransactionBytes(
      feePayer: fromAddress,
      recentBlockhash: recentBlockhash,
      instructions: [
        Instruction(
          programId: Base58.encode(systemProgramId),
          accounts: [
            .writable(fromAddress, signer: true),
            .writable(toAddress)
          ],
          data: transferInstructionData(lamports: lamports)
        )
      ]
    )
  }

  // MARK: - SPL token transfer

  /// Lowercase hex of an unsigned SPL token transfer.
  ///
  /// `createDestinationAccount` prepends the Associated Token Account program's
  /// `CreateIdempotent`, funded by the fee payer — needed when the recipient holds no account for
  /// the mint yet, and harmless (a no-op) if one appears in between.
  static func buildSPLTransferHex(
    owner: String,
    source: String,
    destination: String,
    destinationOwner: String,
    mint: String,
    tokenProgramId: String,
    amount: UInt64,
    decimals: UInt8,
    recentBlockhash: String,
    createDestinationAccount: Bool
  ) throws -> String {
    toHex(
      try buildSPLTransferBytes(
        owner: owner,
        source: source,
        destination: destination,
        destinationOwner: destinationOwner,
        mint: mint,
        tokenProgramId: tokenProgramId,
        amount: amount,
        decimals: decimals,
        recentBlockhash: recentBlockhash,
        createDestinationAccount: createDestinationAccount
      )
    )
  }

  static func buildSPLTransferBytes(
    owner: String,
    source: String,
    destination: String,
    destinationOwner: String,
    mint: String,
    tokenProgramId: String,
    amount: UInt64,
    decimals: UInt8,
    recentBlockhash: String,
    createDestinationAccount: Bool,
    extraReadonlyKeys: [String] = []
  ) throws -> [UInt8] {
    var instructions: [Instruction] = []

    if createDestinationAccount {
      instructions.append(
        Instruction(
          programId: SolanaPrograms.associatedTokenAccount,
          accounts: [
            .writable(owner, signer: true),      // payer
            .writable(destination),              // the account being created
            .readonly(destinationOwner),         // its owner
            .readonly(mint),
            .readonly(SolanaPrograms.system),
            .readonly(tokenProgramId)
          ],
          data: SolanaPrograms.createIdempotentData
        )
      )
    }

    instructions.append(
      Instruction(
        programId: tokenProgramId,
        accounts: [
          .writable(source),
          .readonly(mint),
          .writable(destination),
          .readonly(owner, signer: true)
        ],
        data: SolanaPrograms.transferCheckedData(amount: amount, decimals: decimals)
      )
    )

    return try buildTransactionBytes(
      feePayer: owner,
      recentBlockhash: recentBlockhash,
      instructions: instructions,
      extraReadonlyKeys: extraReadonlyKeys
    )
  }

  // MARK: - Generic serialization

  /// Serializes an unsigned legacy transaction: compact-u16 signature count + one zero-filled
  /// 64-byte fee-payer signature placeholder + the message.
  ///
  /// Only the fee payer ever signs: a required signer besides it would yield a transaction the
  /// single wallet key can never complete, so that is rejected rather than silently emitted.
  ///
  /// `extraReadonlyKeys` are carried in the static key table even though no instruction
  /// references them, placed after the programs as read-only non-signers. A legacy message may
  /// list accounts its instructions never touch, and a fee-sponsored send can require the System
  /// Program there. Keys already in the table are not repeated.
  static func buildTransactionBytes(
    feePayer: String,
    recentBlockhash: String,
    instructions: [Instruction],
    extraReadonlyKeys: [String] = []
  ) throws -> [UInt8] {
    let blockhash = try decodeKey(recentBlockhash, label: "recentBlockhash")
    let accounts = try mergedAccounts(
      feePayer: feePayer,
      instructions: instructions,
      extraReadonlyKeys: extraReadonlyKeys
    )
    let extraSigners = accounts.filter(\.isSigner).count - 1
    guard extraSigners == 0 else {
      throw RainError.invalidConfig(
        details: "Transaction requires \(extraSigners) signer(s) besides the fee payer"
      )
    }

    var tx: [UInt8] = []
    tx.append(contentsOf: compactU16(1))
    tx.append(contentsOf: [UInt8](repeating: 0, count: signatureLength))
    tx.append(
      contentsOf: try serializeMessage(
        accounts: accounts,
        blockhash: blockhash,
        instructions: instructions
      )
    )
    return tx
  }

  /// One entry of the message's account-key table.
  private struct MergedAccount {
    let pubkey: String
    let bytes: [UInt8]
    var isSigner: Bool
    var isWritable: Bool
  }

  /// Orders the account table the header describes: fee payer, writable signers, readonly signers,
  /// writable non-signers, readonly non-signers, then invoked programs last. Within a bucket,
  /// first-seen order, as web3.js does, so a given transfer always serializes to identical bytes.
  private static func mergedAccounts(
    feePayer: String,
    instructions: [Instruction],
    extraReadonlyKeys: [String] = []
  ) throws -> [MergedAccount] {
    // Programs go last, first-seen, and are excluded from the merged table below.
    var programOrder: [String] = []
    var programBytes: [String: [UInt8]] = [:]
    for instruction in instructions where programBytes[instruction.programId] == nil {
      programBytes[instruction.programId] = try decodeKey(instruction.programId, label: "program")
      programOrder.append(instruction.programId)
    }
    let programKeys = Set(programOrder)

    // Merge accounts (excluding fee payer and programs), OR-ing privileges across duplicates.
    var mergedOrder: [String] = []
    var merged: [String: MergedAccount] = [:]
    for instruction in instructions {
      for account in instruction.accounts {
        if account.pubkey == feePayer || programKeys.contains(account.pubkey) { continue }
        if var existing = merged[account.pubkey] {
          existing.isSigner = existing.isSigner || account.isSigner
          existing.isWritable = existing.isWritable || account.isWritable
          merged[account.pubkey] = existing
        } else {
          merged[account.pubkey] = MergedAccount(
            pubkey: account.pubkey,
            bytes: try decodeKey(account.pubkey, label: "account"),
            isSigner: account.isSigner,
            isWritable: account.isWritable
          )
          mergedOrder.append(account.pubkey)
        }
      }
    }

    // Stable partition: `filter` preserves first-seen order within each bucket.
    let rest = mergedOrder.map { merged[$0]! }
    let payer = MergedAccount(
      pubkey: feePayer,
      bytes: try decodeKey(feePayer, label: "fee payer"),
      isSigner: true,
      isWritable: true
    )
    let programs = programOrder.map { key in
      MergedAccount(pubkey: key, bytes: programBytes[key]!, isSigner: false, isWritable: false)
    }

    // Unreferenced keys the caller wants carried anyway, after the programs, once each.
    var extras: [MergedAccount] = []
    for key in extraReadonlyKeys
    where key != feePayer && merged[key] == nil && !programKeys.contains(key)
      && !extras.contains(where: { $0.pubkey == key }) {
      extras.append(MergedAccount(
        pubkey: key,
        bytes: try decodeKey(key, label: "extra account"),
        isSigner: false,
        isWritable: false
      ))
    }

    return [payer]
      + rest.filter { $0.isSigner && $0.isWritable }
      + rest.filter { $0.isSigner && !$0.isWritable }
      + rest.filter { !$0.isSigner && $0.isWritable }
      + rest.filter { !$0.isSigner && !$0.isWritable }
      + programs
      + extras
  }

  private static func serializeMessage(
    accounts: [MergedAccount],
    blockhash: [UInt8],
    instructions: [Instruction]
  ) throws -> [UInt8] {
    var out: [UInt8] = []

    // Message header.
    out.append(UInt8(accounts.filter(\.isSigner).count))
    out.append(UInt8(accounts.filter { $0.isSigner && !$0.isWritable }.count))
    out.append(UInt8(accounts.filter { !$0.isSigner && !$0.isWritable }.count))

    // Account keys.
    out.append(contentsOf: compactU16(accounts.count))
    for account in accounts {
      out.append(contentsOf: account.bytes)
    }

    // Recent blockhash.
    out.append(contentsOf: blockhash)

    // Instructions, referencing accounts by index into the table above.
    var indexByPubkey: [String: UInt8] = [:]
    for (index, account) in accounts.enumerated() {
      indexByPubkey[account.pubkey] = UInt8(index)
    }

    out.append(contentsOf: compactU16(instructions.count))
    for instruction in instructions {
      guard let programIndex = indexByPubkey[instruction.programId] else {
        throw RainError.internalError(
          details: "Program \(instruction.programId) missing from the account table"
        )
      }
      out.append(programIndex)
      out.append(contentsOf: compactU16(instruction.accounts.count))
      for account in instruction.accounts {
        guard let index = indexByPubkey[account.pubkey] else {
          throw RainError.internalError(
            details: "Account \(account.pubkey) missing from the account table"
          )
        }
        out.append(index)
      }
      out.append(contentsOf: compactU16(instruction.data.count))
      out.append(contentsOf: instruction.data)
    }

    return out
  }

  /// SystemProgram transfer data: u32 LE instruction index (2) followed by u64 LE lamports.
  private static func transferInstructionData(lamports: UInt64) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 12)
    writeU32LE(&data, offset: 0, value: systemTransferInstructionIndex)
    writeU64LE(&data, offset: 4, value: lamports)
    return data
  }

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

  /// Solana short-vec (compact-u16) length encoding: 7 bits per byte, MSB = continuation.
  static func compactU16(_ value: Int) -> [UInt8] {
    precondition(value >= 0 && value <= 0xFFFF, "compact-u16 out of range: \(value)")
    var out: [UInt8] = []
    var remaining = value
    while true {
      let low = remaining & 0x7F
      remaining >>= 7
      if remaining == 0 {
        out.append(UInt8(low))
        break
      }
      out.append(UInt8(low | 0x80))
    }
    return out
  }

  private static func writeU32LE(_ target: inout [UInt8], offset: Int, value: UInt32) {
    var v = value
    for i in 0..<4 {
      target[offset + i] = UInt8(truncatingIfNeeded: v)
      v >>= 8
    }
  }

  private static func writeU64LE(_ target: inout [UInt8], offset: Int, value: UInt64) {
    var v = value
    for i in 0..<8 {
      target[offset + i] = UInt8(truncatingIfNeeded: v)
      v >>= 8
    }
  }

  /// Lowercase hex of arbitrary bytes — the encoding Turnkey's `sol_send_transaction` expects.
  static func hexEncode(_ bytes: [UInt8]) -> String {
    toHex(bytes)
  }

  private static func toHex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    var chars: [Character] = []
    chars.reserveCapacity(bytes.count * 2)
    for b in bytes {
      chars.append(digits[Int(b >> 4)])
      chars.append(digits[Int(b & 0x0F)])
    }
    return String(chars)
  }
}
