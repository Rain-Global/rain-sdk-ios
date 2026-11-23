import Foundation

/// Result of an ERC-20 approval submitted by
/// ``RainClient/approveTokenAllowance(chainId:contractAddress:spender:amount:decimals:)``.
///
/// The wrapper exists so the public surface stays forward-compatible — future versions can
/// attach richer metadata (status, included block, fee paid) without breaking the call shape.
public struct RainTokenApprovalResult: Sendable, Equatable {
  /// The on-chain transaction hash of the `approve` call.
  ///
  /// The approval is only in effect once that transaction is mined; read the allowance back
  /// with ``RainClient/getTokenAllowance(chainId:contractAddress:spender:owner:)``
  /// to confirm.
  public let transactionHash: String

  public init(transactionHash: String) {
    self.transactionHash = transactionHash
  }
}
