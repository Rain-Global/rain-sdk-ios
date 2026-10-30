import Foundation
import Web3

/// An unsigned Solana transfer ready for a wallet provider to sign. Public so out-of-core adapters
/// (e.g. `RainPrivy`) can receive one through ``RainSolanaSupport``.
public struct UnsignedSolanaTransfer: Sendable {
  /// The serialized unsigned transaction — the bytes that were simulated, so callers sign these
  /// and not a rebuilt variant.
  public let transaction: Data
  public let recentBlockhash: String
  /// Whether the transfer also creates the recipient's token account, whose rent the sender pays
  /// unless the provider sponsors it (`WalletProvider.sponsorsRent`).
  public let createsRecipientAccount: Bool

  /// Lowercase hex of ``transaction`` — the encoding Turnkey's `sol_send_transaction` expects.
  public var transactionHex: String {
    SolanaTransactionBuilder.hexEncode([UInt8](transaction))
  }

  internal init(transaction: [UInt8], recentBlockhash: String, createsRecipientAccount: Bool = false) {
    self.transaction = Data(transaction)
    self.recentBlockhash = recentBlockhash
    self.createsRecipientAccount = createsRecipientAccount
  }
}

/// Composes unsigned Solana transfers, running every preflight the SDK requires before a wallet
/// provider signs: address validation, mint resolution, associated-token-account derivation and
/// creation, balance and fee checks, and a simulation dry run for SPL transfers. Providers only
/// sign and broadcast the result, so the checks cannot drift between them.
@_spi(RainAdapter) public struct SolanaTransferComposer: Sendable {
  private let rpcClient: SolanaRpcClient

  init(rpcClient: SolanaRpcClient) {
    self.rpcClient = rpcClient
  }

  /// A native SOL transfer. `amount` is converted exactly; sub-lamport precision is rejected
  /// rather than truncated.
  @_spi(RainAdapter) public func composeNative(
    chainId: Int,
    from fromAddress: String,
    to toAddress: String,
    amount: Decimal
  ) async throws -> UnsignedSolanaTransfer {
    guard amount >= 0 else {
      throw RainError.invalidAmount(amount: "\(amount)", reason: "must not be negative")
    }
    let lamports = try Self.exactBaseUnits(
      amount: amount,
      decimals: SolanaConverter.solDecimals,
      unitLabel: "SOL"
    )
    let blockhash = try await rpcClient.getLatestBlockhash(chainId: chainId)
    let transaction = try SolanaTransactionBuilder.buildTransferBytes(
      from: fromAddress,
      to: toAddress,
      lamports: try Self.u64BaseUnits(lamports, amount: amount),
      recentBlockhash: blockhash
    )
    return UnsignedSolanaTransfer(transaction: transaction, recentBlockhash: blockhash)
  }

  /// An SPL transfer, creating the recipient's token account in the same transaction when they do
  /// not have one yet.
  ///
  /// Tokens live in per-mint *token accounts*, not in the wallet itself, so `toAddress` is the
  /// recipient's wallet and the account that actually receives the transfer is derived from it.
  /// Creating a missing recipient account costs the sender its rent unless `sponsoredRent`. The
  /// sender stays the payer either way: Turnkey pre-funds the payer, not a separate account.
  ///
  /// The mint is read from the chain first: its decimals scale `amount`, and the token program
  /// that owns it both receives the transfer and seeds the token-account derivation. The transfer
  /// is simulated against the cluster while still unsigned, so a failure surfaces as a typed error
  /// rather than as a broadcast that quietly fails on chain.
  ///
  /// `sponsoredFees` opts out of the two self-paid preflights — the fee-lamport check and the
  /// dry run — for a provider whose sends are fee-sponsored: both would false-fail exactly the
  /// zero-SOL wallets sponsorship exists for; `sponsoredRent` drops the rent term too. A
  /// sponsored send's failures then surface through the provider's send status instead of as a
  /// typed preflight error.
  @_spi(RainAdapter) public func composeSPLToken(
    chainId: Int,
    from fromAddress: String,
    mintAddress: String,
    to toAddress: String,
    amount: Decimal,
    sponsoredFees: Bool = false,
    sponsoredRent: Bool = false
  ) async throws -> UnsignedSolanaTransfer {
    try Self.validateAddress(fromAddress, label: "sender")
    try Self.validateAddress(toAddress, label: "recipient")
    try Self.validateAddress(mintAddress, label: "mint")
    guard fromAddress != toAddress else {
      throw RainError.invalidRecipient(address: toAddress, reason: "the recipient is this wallet")
    }

    // Checked before scaling, so a negative amount reports what is actually wrong with it rather
    // than the decimal-places message scaling would produce.
    guard amount > 0 else {
      throw RainError.invalidAmount(amount: "\(amount)", reason: "must be greater than zero")
    }
    guard let mint = try await rpcClient.getMintInfo(chainId: chainId, mint: mintAddress) else {
      throw RainError.tokenNotFound(token: mintAddress, chainId: chainId)
    }
    let baseUnits = try Self.exactBaseUnits(
      amount: amount,
      decimals: mint.decimals,
      unitLabel: "this token"
    )

    // The recipient must be a wallet. Passing a token account instead would derive a token account
    // *of* a token account — a well-formed address nobody can spend from.
    if let recipientAccount = try await rpcClient.getAccountInfo(chainId: chainId, address: toAddress),
       SolanaPrograms.isTokenProgram(recipientAccount.ownerProgram) {
      throw RainError.invalidRecipient(
        address: toAddress,
        reason: "this address belongs to a token program (a token account or a mint); "
          + "pass the recipient's wallet address instead"
      )
    }

    let source = try SolanaProgramAddress.associatedTokenAddress(
      owner: fromAddress, mint: mintAddress, tokenProgramId: mint.tokenProgramId
    )
    let destination = try SolanaProgramAddress.associatedTokenAddress(
      owner: toAddress, mint: mintAddress, tokenProgramId: mint.tokenProgramId
    )

    guard let sourceAccount = try await rpcClient.getTokenAccount(chainId: chainId, address: source)
    else {
      throw RainError.tokenAccountNotFound(walletAddress: fromAddress, token: mintAddress)
    }
    guard sourceAccount.rawAmount >= baseUnits else {
      throw RainError.insufficientTokenBalance(
        requested: "\(amount)",
        available: EthereumConverter
          .baseUnitsToDecimal(sourceAccount.rawAmount, decimals: mint.decimals)
          .description,
        token: mintAddress
      )
    }

    let createDestination = !(try await rpcClient.accountExists(chainId: chainId, address: destination))
    try await SolanaLamportPreflight.require(
      rpcClient: rpcClient,
      chainId: chainId,
      address: fromAddress,
      includeAccountRent: createDestination,
      feesSponsored: sponsoredFees,
      rentSponsored: sponsoredRent
    )

    let blockhash = try await rpcClient.getLatestBlockhash(chainId: chainId)
    let transaction = try SolanaTransactionBuilder.buildSPLTransferBytes(
      owner: fromAddress,
      source: source,
      destination: destination,
      destinationOwner: toAddress,
      mint: mintAddress,
      tokenProgramId: mint.tokenProgramId,
      amount: try Self.u64BaseUnits(baseUnits, amount: amount),
      decimals: UInt8(mint.decimals),
      recentBlockhash: blockhash,
      createDestinationAccount: createDestination,
      // Sponsored Solana sends can require the System Program among the static account keys. A
      // transfer into an existing token account never references it (only the token program
      // does), so it is carried explicitly; the self-paid message is unchanged.
      extraReadonlyKeys: sponsoredFees ? [SolanaPrograms.system] : []
    )
    // The dry run charges the fee to the sender, so for a sponsored transfer it would false-fail
    // exactly the zero-SOL wallets sponsorship exists for.
    if !sponsoredFees {
      try await simulate(chainId: chainId, transaction: transaction)
    }

    RainLogger.debug(
      """
      Rain SDK: sending \(baseUnits.description) of mint \(mintAddress) on chainId=\(chainId) \
      (creating recipient token account: \(createDestination))
      """
    )
    return UnsignedSolanaTransfer(
      transaction: transaction,
      recentBlockhash: blockhash,
      createsRecipientAccount: createDestination
    )
  }

  // MARK: - Preflight helpers

  /// Scales a human-readable `amount` to base units, rejecting anything finer than the unit can
  /// represent rather than silently truncating it.
  private static func exactBaseUnits(
    amount: Decimal,
    decimals: Int,
    unitLabel: String
  ) throws -> BigUInt {
    do {
      return try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
    } catch {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "\(unitLabel) supports at most \(decimals) decimal places"
      )
    }
  }

  /// Narrows base units to the `UInt64` Solana instructions encode amounts in. A value past that
  /// width is rejected rather than truncated: truncation would send a *different* amount (often
  /// zero) that still simulates and broadcasts fine, which is worse than failing.
  private static func u64BaseUnits(_ baseUnits: BigUInt, amount: Decimal) throws -> UInt64 {
    guard let value = UInt64(baseUnits.description) else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "is too large to encode — Solana amounts are 64-bit"
      )
    }
    return value
  }

  private static func validateAddress(_ address: String, label: String) throws {
    guard (try? Base58.decode(address))?.count == 32 else {
      throw RainError.internalError(details: "Invalid Solana \(label) address: \(address)")
    }
  }

  /// Dry-runs the unsigned transaction, translating a simulation failure into a typed error. A
  /// lamport shortfall the runtime refused is `insufficientFunds`: the preflight's estimate is
  /// approximate (flat fee, 165-byte account), so the runtime's word wins.
  private func simulate(chainId: Int, transaction: [UInt8]) async throws {
    let simulation = try await rpcClient.simulateTransaction(
      chainId: chainId,
      base64Transaction: Data(transaction).base64EncodedString()
    )
    guard !simulation.succeeded else { return }
    if simulation.fundsShortfall {
      throw RainError.insufficientFunds(required: "unknown", available: "unknown")
    }

    RainLogger.error(
      """
      Rain SDK: Solana transaction simulation failed: \(simulation.error ?? "unknown"); \
      logs: \(simulation.logs.joined(separator: " | "))
      """
    )
    throw RainError.transactionSimulationFailed(
      underlying: RainError.internalError(
        details: simulation.error ?? "Solana transaction simulation failed"
      )
    )
  }
}
