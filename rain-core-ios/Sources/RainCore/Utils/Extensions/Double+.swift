import Foundation
import Web3

extension Double {
  public var weiToEth: Double {
    self / pow(10, 18)
  }
  
  var ethToWei: Double {
    self * pow(10, 18)
  }
  
  /// Hex-encodes a wei-magnitude value. Builds the integer as `BigUInt` so values above
  /// `Int64.max` don't trap the way `Int(self)` would; truncates any sub-unit fraction toward zero.
  var toHexString: String {
    let integerString = String(format: "%.0f", self.rounded(.towardZero))
    let wei = BigUInt(integerString, radix: 10) ?? BigUInt(0)
    return "0x" + String(wei, radix: 16)
  }

  /// Shortest exact `Decimal` matching this value's printed form (e.g. `0.1` → `Decimal(string: "0.1")`).
  /// Use at `Double → Decimal` boundaries; avoids `Decimal(aDouble)`, which would capture the
  /// full float error (`Decimal(0.1)` is `0.10000000000000000555…`). Non-finite input (NaN,
  /// ±infinity) has no `Decimal` counterpart and surfaces as `Decimal.nan`, so downstream amount
  /// validation rejects it as invalid instead of treating it as 0.
  var asDecimal: Decimal {
    guard isFinite else { return .nan }
    return Decimal(string: String(self)) ?? .nan
  }
}
