import Foundation
import Web3

/// A token balance with exact base-unit precision plus resolved display metadata.
///
/// `rawAmount` is the exact on-chain value in the token's smallest unit (wei-equivalent);
/// it is never lossy. `decimalAmount` and `formatted` are derived for display.
public struct Balance: Sendable, Equatable, Hashable {
  /// Which token this balance is for (`.native` or a `.contract`).
  public let token: Token

  /// EIP-155 chain ID the balance was read on. Keeps merged, cross-chain lists self-describing.
  public let chainId: Int

  /// Exact balance in the token's smallest unit (e.g. wei for an 18-decimal token).
  public let rawAmount: BigUInt

  /// Number of decimal places the token uses (e.g. 6 for USDC, 18 for ETH).
  public let decimals: Int

  /// Token symbol (e.g. "USDC"), when known.
  public let symbol: String?

  /// Human-readable token name (e.g. "USD Coin"), when known.
  public let name: String?

  public init(
    token: Token,
    chainId: Int,
    rawAmount: BigUInt,
    decimals: Int,
    symbol: String? = nil,
    name: String? = nil
  ) {
    self.token = token
    self.chainId = chainId
    self.rawAmount = rawAmount
    self.decimals = decimals
    self.symbol = symbol
    self.name = name
  }

  /// The balance as a precise `Decimal` (`rawAmount / 10^decimals`).
  public var decimalAmount: Decimal {
    let raw = NSDecimalNumber(string: rawAmount.description)
    let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(decimals), isNegative: false)
    return raw.dividing(by: divisor).decimalValue
  }

  /// Human-readable balance string (e.g. `"1.5"`): plain notation, trailing
  /// fractional zeros trimmed (`"1.0"` → `"1"`, `"0.500"` → `"0.5"`).
  public var formatted: String {
    var text = NSDecimalNumber(decimal: decimalAmount)
      .description(withLocale: Locale(identifier: "en_US_POSIX"))
    guard text.contains(".") else { return text }
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }
}
