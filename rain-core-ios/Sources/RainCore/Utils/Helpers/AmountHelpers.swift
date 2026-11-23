import Foundation
import Web3

/// Utility functions for amount conversion and validation
public enum AmountHelpers {
  /// Strict-parses a decimal literal. Anything else — hex like `"0x123"`, trailing junk, empty —
  /// returns `nil` rather than a silent partial parse: `Decimal(string:)` alone takes the longest
  /// valid prefix, so `"0x10"` would yield `0`.
  public static func strictDecimal(from raw: String) -> Decimal? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = "^[+-]?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"
    guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
    return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
  }

  /// Rounds down (toward −∞) to whole base units. Compared against the unrounded value to detect
  /// an amount finer than the token can hold, and keeps the string output free of a decimal point
  /// or exponent.
  private static let roundDownBehavior = NSDecimalNumberHandler(
    roundingMode: .down,
    scale: 0,
    raiseOnExactness: false,
    raiseOnOverflow: false,
    raiseOnUnderflow: false,
    raiseOnDivideByZero: false
  )

  /// Scales without rounding and without raising: the default handler throws Objective-C
  /// exceptions on overflow, which no Swift `catch` can intercept, so an out-of-range amount would
  /// terminate the process instead of returning an error.
  private static let exactBehavior = NSDecimalNumberHandler(
    roundingMode: .plain,
    scale: Int16(NSDecimalNoScale),
    raiseOnExactness: false,
    raiseOnOverflow: false,
    raiseOnUnderflow: false,
    raiseOnDivideByZero: false
  )

  /// Converts a human-readable `Decimal` amount to `BigUInt` base units (wei) with precision safety.
  /// Throws `RainError.invalidAmount` if the amount has more decimal places than the token allows,
  /// or cannot be represented as non-negative base units.
  public static func toBaseUnits(
    amount: Decimal,
    decimals: Int
  ) throws -> BigUInt {
    guard !amount.isNaN else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "amount is not a number"
      )
    }

    // `Int16(decimals)` below traps on overflow, so an out-of-range value would crash the process
    // rather than throw — and `decimals` can come from an on-chain `decimals()` read, i.e. from a
    // contract the SDK does not control. 77 is the ceiling that means anything: uint256 max is
    // ~1.16e77, so one whole unit of a finer token is unrepresentable.
    guard (0...77).contains(decimals) else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "token decimals must be between 0 and 77, got \(decimals)"
      )
    }

    // Scale by 10^decimals on Decimal (exact base-10). Checked for integrality by value rather
    // than by comparing scales: `250.0000000` is exactly representable at 6 decimals even though
    // it carries seven, while `1.2345678` is not, and only the value distinguishes the two.
    let scaled = NSDecimalNumber(decimal: amount)
      .multiplying(byPowerOf10: Int16(decimals), withBehavior: exactBehavior)
    let truncated = scaled.rounding(accordingToBehavior: roundDownBehavior)

    guard scaled == truncated else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "amount has fractional base units for a \(decimals)-decimal token"
      )
    }

    guard let baseUnits = BigUInt(truncated.stringValue, radix: 10) else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "could not be converted to base units (\"\(truncated.stringValue)\")"
      )
    }

    // `BigUInt` is unbounded, but the ABI slot it lands in is not: a value past uint256 max would
    // be silently truncated by the encoder into a completely different allowance or transfer.
    guard baseUnits <= maxUInt256 else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "amount exceeds the maximum ERC-20 uint256 value"
      )
    }

    return baseUnits
  }

  /// The largest value an ABI `uint256` slot can carry.
  private static let maxUInt256: BigUInt = BigUInt(2).power(256) - 1
}
