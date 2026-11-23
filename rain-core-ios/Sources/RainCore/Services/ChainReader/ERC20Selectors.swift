import Foundation

/// 4-byte method selectors for ERC-20 functions (`keccak256(signature)[:4]`).
/// Centralized so the hex literals don't sprawl across adapters.
internal enum ERC20Selectors {
  /// `balanceOf(address)`
  static let balanceOf = "70a08231"

  /// `symbol()`
  static let symbol = "95d89b41"

  /// `name()`
  static let name = "06fdde03"

  /// `decimals()`
  static let decimals = "313ce567"

  /// `allowance(address,address)`
  static let allowance = "dd62ed3e"

  /// `approve(address,uint256)`
  static let approve = "095ea7b3"
}
