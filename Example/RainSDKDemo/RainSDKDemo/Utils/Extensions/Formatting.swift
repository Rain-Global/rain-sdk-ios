import Foundation

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Decimal {
  /// Plain decimal string, trailing zeros stripped and never in scientific notation.
  var plainString: String {
    var value = self
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 18, .plain)
    return NSDecimalNumber(decimal: rounded).stringValue
  }

  /// Fixed-precision rendering for balance labels (e.g. `1.50`, `12.345678`).
  func formatted(places: Int) -> String {
    String(format: "%.\(places)f", NSDecimalNumber(decimal: self).doubleValue)
  }
}

/// Shortens an address for display: `0x1234…abcd`.
func formatAddress(_ address: String) -> String {
  address.count > 10 ? "\(address.prefix(6))…\(address.suffix(4))" : address
}
