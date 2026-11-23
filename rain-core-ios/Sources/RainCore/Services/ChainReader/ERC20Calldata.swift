import Foundation

/// Hand-rolled calldata for the ERC-20 *read* functions the chain reader issues.
///
/// Write-path calldata (`transfer`, `approve`) is encoded by `TransactionBuilderService`
/// against the ERC-20 contract interface — this is only for `eth_call` reads, matching how
/// `Multicall3.encodeBalanceOf` already encodes `balanceOf` here.
internal enum ERC20Calldata {
  /// `allowance(owner, spender)` — how much of `owner`'s balance `spender` may still move.
  static func allowance(owner: String, spender: String) -> String {
    "0x" + ERC20Selectors.allowance + word(owner) + word(spender)
  }

  /// Left-pads a 20-byte address into a 32-byte ABI word.
  private static func word(_ address: String) -> String {
    let clean = address.strippingHexPrefix.lowercased()
    return String(repeating: "0", count: max(0, 64 - clean.count)) + clean
  }
}
