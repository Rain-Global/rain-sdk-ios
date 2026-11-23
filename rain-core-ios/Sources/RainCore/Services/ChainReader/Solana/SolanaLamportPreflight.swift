import Foundation
import Web3

/// The SOL a wallet must hold before a composed transaction is handed to a provider, shared by the
/// transfer and collateral-withdrawal composers so the two cannot drift: the fee unless sponsored,
/// plus the rent of a token account the transaction creates unless sponsored, read from the
/// cluster. A friendlier up-front error than a broadcast that fails on chain; a self-paid
/// transaction is simulated afterwards as well.
internal enum SolanaLamportPreflight {
  /// Base fee for a single-signature Solana transaction.
  static let feeLamports: UInt64 = 5_000

  /// The classic SPL token account. A Token-2022 associated account carries extensions and is
  /// larger; the dry run catches the difference.
  static let tokenAccountSize = 165

  /// Throws `RainError.insufficientFunds` when `address` cannot cover the fee (unless
  /// `feesSponsored`) plus a token account's rent (when `includeAccountRent`, unless
  /// `rentSponsored`). Reads nothing it does not need.
  static func require(
    rpcClient: SolanaRpcClient,
    chainId: Int,
    address: String,
    includeAccountRent: Bool,
    feesSponsored: Bool,
    rentSponsored: Bool
  ) async throws {
    let rent: BigUInt = if includeAccountRent && !rentSponsored {
      try await rpcClient.getMinimumBalanceForRentExemption(chainId: chainId, dataLength: tokenAccountSize)
    } else {
      0
    }
    let required = (feesSponsored ? BigUInt(0) : BigUInt(feeLamports.description) ?? 0) + rent
    if required == 0 { return }
    let lamports = try await rpcClient.getBalanceLamports(chainId: chainId, address: address)
    guard lamports >= required else {
      RainLogger.warning(
        "Rain SDK: wallet \(address) holds \(lamports) lamports, needs \(required) for this transaction"
      )
      throw RainError.insufficientFunds(
        required: SolanaConverter.lamportsToSol(required).description,
        available: SolanaConverter.lamportsToSol(lamports).description
      )
    }
  }
}
