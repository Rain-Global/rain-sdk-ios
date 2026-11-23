import Foundation

/// EIP-712 typed-data signing capability. Public so out-of-core adapters (e.g. `RainPortal`)
/// can conform. Providers that can produce an admin signature for withdrawals implement this.
public protocol RainTypedDataSignerProvider: Sendable {
  func signTypedData(
    chainId: Int,
    walletAddress: String,
    typedData: String
  ) async throws -> String
}

/// Gas / fee estimation capability. Public so out-of-core adapters can conform.
///
/// Returns the estimated total fee (estimated gas × gas price) in the chain's native token as a
/// `Decimal`. Implementations must keep the wei-level math exact (`BigUInt` for raw values,
/// `Decimal` for the final division), with no intermediate `Double`.
public protocol RainTransactionFeeEstimatingProvider: Sendable {
  func estimateTransactionFee(
    chainId: Int,
    walletAddress: String,
    params: WalletTransactionParams
  ) async throws -> Decimal
}

/// Solana transfers (native SOL + SPL tokens). Public so out-of-core adapters can conform.
/// Implemented by providers that manage a Solana account (e.g. Turnkey, Privy).
///
/// SOL amounts are scaled at 1e9 lamports, SPL token amounts at the mint's `decimals` — both
/// paths get a dedicated entry point rather than flowing through the EVM `WalletTransactionParams`
/// (1e18-scaled hex `value`).
public protocol RainSolanaTransfersProvider: Sendable {
  /// Signs and broadcasts a native SOL transfer.
  ///
  /// - Parameters:
  ///   - chainId: Solana sentinel chain ID (900 / 901 / 902).
  ///   - to: Recipient base58 address.
  ///   - amount: Human-readable SOL amount (e.g. 0.5).
  /// - Returns: The Solana transaction signature.
  func sendSolanaNative(
    chainId: Int,
    to toAddress: String,
    amount: Decimal
  ) async throws -> String

  /// Signs and broadcasts an SPL token transfer (TransferChecked instruction, auto-creating
  /// the recipient associated token account when needed).
  ///
  /// - Parameters:
  ///   - chainId: Solana sentinel chain ID (900 / 901 / 902).
  ///   - mintAddress: SPL mint address (base58).
  ///   - to: Recipient wallet base58 address (NOT the recipient ATA — the SDK derives that).
  ///   - amount: Human-readable token amount (e.g. 1.5 for 1.5 USDC).
  ///   - decimals: Not authoritative, and 0 when the caller supplied none — never scale the amount
  ///     with it. Read the mint's decimals and pass those to `TransferChecked`; the token program
  ///     rejects a mismatch (`TokenError` 18). 0 is also a legal mint value, so never branch on it.
  /// - Returns: The Solana transaction signature.
  func sendSolanaSPLToken(
    chainId: Int,
    mintAddress: String,
    to toAddress: String,
    amount: Decimal,
    decimals: Int
  ) async throws -> String

  /// Signs and broadcasts a transaction **composed by core**, rather than one the adapter builds.
  ///
  /// Collateral withdrawals are composed in core (the ed25519 proof of Rain's signature plus the
  /// program's withdraw instruction), so the adapter only signs the bytes it is handed — it must
  /// not rebuild or re-serialize them, or the executor's signature would no longer match.
  ///
  /// - Parameters:
  ///   - chainId: Solana sentinel chain ID (900 / 901 / 902).
  ///   - unsigned: The already-simulated unsigned transaction.
  /// - Returns: The Solana transaction signature.
  func signAndSendSolanaTransaction(
    chainId: Int,
    unsigned: UnsignedSolanaTransfer
  ) async throws -> String
}
