//
//  RainPreparedWithdrawal.swift
//  RainSDK
//

import Foundation

/// A collateral withdrawal built but not broadcast, in the shape the target chain requires.
///
/// Not offline: building this still prompts the wallet to sign EIP-712 (EVM) and reads the
/// collateral's admin set on chain. A Solana blockhash lasts ~150 slots (60-90s) — submit
/// promptly or re-prepare.
public enum RainPreparedWithdrawal: Sendable {
  /// A complete, submittable EVM transaction — `from` / `to` / `value` / `data`, not bare calldata.
  case evm(RainTransactionParameters)

  /// The serialized unsigned Solana transaction, already simulated, with its recent blockhash.
  case solana(UnsignedSolanaTransfer)

  /// The EVM parameters, or `nil` on a Solana withdrawal.
  public var evmParameters: RainTransactionParameters? {
    if case let .evm(parameters) = self { return parameters }
    return nil
  }

  /// The unsigned Solana transfer, or `nil` on an EVM withdrawal.
  public var solanaTransfer: UnsignedSolanaTransfer? {
    if case let .solana(transfer) = self { return transfer }
    return nil
  }
}
