import Foundation
import Web3

/// An ERC-20 allowance: how much of `owner`'s token balance `spender` may still move.
///
/// `rawAmount` is the exact on-chain value in the token's smallest unit and is never lossy — it is
/// the value to compare against. ``decimalAmount`` and ``formatted`` are derived for display and
/// round past 38 significant digits, so check ``isUnlimited`` before rendering a number.
public struct RainTokenAllowance: Sendable, Equatable {
  /// The maximum `uint256`, the value an unlimited approval sets.
  public static let unlimitedRawAmount: BigUInt = BigUInt(2).power(256) - 1

  /// EIP-155 chain ID the allowance was read on.
  public let chainId: Int

  /// The ERC-20 token contract the allowance is against.
  public let tokenAddress: String

  /// The wallet whose balance may be moved.
  public let owner: String

  /// The address allowed to move it — the user's collateral contract, for Auth Pull.
  public let spender: String

  /// Exact allowance in the token's smallest unit.
  public let rawAmount: BigUInt

  /// Number of decimal places the token uses (e.g. 6 for USDC).
  public let decimals: Int

  public init(
    chainId: Int,
    tokenAddress: String,
    owner: String,
    spender: String,
    rawAmount: BigUInt,
    decimals: Int
  ) {
    self.chainId = chainId
    self.tokenAddress = tokenAddress
    self.owner = owner
    self.spender = spender
    self.rawAmount = rawAmount
    self.decimals = decimals
  }

  /// Whether this is the unlimited (`uint256` max) allowance the SDK sets when an approval
  /// amount is omitted.
  ///
  /// Exact by design. Some tokens decrement even a max allowance on every `transferFrom`, so a
  /// wallet approved as unlimited can later report `false` here while still holding a very
  /// large allowance — compare ``rawAmount`` against the amount you need rather than treating
  /// `false` as "must re-approve".
  public var isUnlimited: Bool { rawAmount == Self.unlimitedRawAmount }

  /// Nothing is approved — the state after a revoke, and before any approval.
  public var isZero: Bool { rawAmount == 0 }

  /// The allowance as a `Decimal` (`rawAmount / 10^decimals`), for display.
  ///
  /// `Decimal` carries 38 significant digits, so an unlimited allowance — 72 digits once scaled by
  /// USDC's 6 — is rounded here and its low-order digits are lost. That is display-only:
  /// ``rawAmount`` stays exact, and ``covers(_:)`` compares against it. Gate on ``isUnlimited``
  /// before showing a number; a 72-digit USDC figure is not worth rendering.
  public var decimalAmount: Decimal {
    EthereumConverter.baseUnitsToDecimal(rawAmount, decimals: decimals)
  }

  /// Human-readable allowance (e.g. `"1.5"`): plain notation, trailing fractional zeros trimmed.
  /// Carries the same rounding caveat as ``decimalAmount``.
  public var formatted: String {
    var text = NSDecimalNumber(decimal: decimalAmount)
      .description(withLocale: Locale(identifier: "en_US_POSIX"))
    guard text.contains(".") else { return text }
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }

  /// Whether `amount` (human-readable, at this token's ``decimals``) is still covered by the
  /// allowance — the check to run before an Auth Pull authorization.
  ///
  /// An amount that cannot be represented at all — negative, or finer than the token's scale —
  /// is `false` too, so `false` means "do not rely on this allowance", not "approve more".
  public func covers(_ amount: Decimal) -> Bool {
    guard let required = try? AmountHelpers.toBaseUnits(amount: amount, decimals: decimals) else {
      return false
    }
    return rawAmount >= required
  }
}
