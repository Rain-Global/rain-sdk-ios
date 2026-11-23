//
//  RainTokenTransferResult.swift
//  RainSDK
//

import Foundation

/// Result returned after performing a token transfer.
///
/// Returned by `sendNative(...)` and `sendToken(...)`. The wrapper exists so the
/// public surface stays forward-compatible — future versions can attach richer metadata
/// (status, included block, fee paid) without breaking the call shape.
///
public struct RainTokenTransferResult: Sendable, Equatable {
  /// The on-chain transaction hash (EVM) or transaction signature (Solana).
  ///
  /// For Turnkey-backed Solana sends, this may briefly be a Turnkey activity status id
  /// before the SDK recovers the real signature — see the adapter's polling + RPC
  /// fallback for details.
  public let transactionHash: String

  public init(transactionHash: String) {
    self.transactionHash = transactionHash
  }
}
