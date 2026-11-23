import Testing
import Foundation
import Web3
@testable import RainCore

@Suite("AmountHelpers.toBaseUnits")
struct AmountHelpersTests {

  @Test("in-range amounts do not throw on the scale guard")
  func inRangeAmountsDoNotThrow() throws {
    #expect(throws: Never.self) { try AmountHelpers.toBaseUnits(amount: Decimal(string: "16.38")!, decimals: 6) }
    #expect(throws: Never.self) { try AmountHelpers.toBaseUnits(amount: Decimal(string: "26.83")!, decimals: 6) }
    #expect(throws: Never.self) { try AmountHelpers.toBaseUnits(amount: Decimal(string: "0.00019472")!, decimals: 18) }
  }

  @Test("amount with more decimal places than the token throws")
  func overPrecisionThrows() {
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: Decimal(string: "0.1234567")!, decimals: 6)
    }
  }

  @Test("converts a representable amount to exact base units")
  func exactBaseUnits() throws {
    let baseUnits = try AmountHelpers.toBaseUnits(amount: Decimal(string: "0.00019472")!, decimals: 18)
    #expect(baseUnits == BigUInt(194_720_000_000_000))
  }

  @Test("is exact where a Double multiply would truncate")
  func exactWhereDoubleDrifts() throws {
    // 16.38 * 1e6 in Double == 16_379_999.999… -> the old BigUInt(Double) truncated to 16_379_999.
    let baseUnits = try AmountHelpers.toBaseUnits(amount: Decimal(string: "16.38")!, decimals: 6)
    #expect(baseUnits == BigUInt(16_380_000))
  }

  /// Integrality is a property of the value, not of the declared scale: these carry more decimal
  /// places than the token but land on whole base units anyway.
  @Test("representable trailing zeros are accepted")
  func representableTrailingZerosAccepted() throws {
    #expect(try AmountHelpers.toBaseUnits(amount: Decimal(string: "250.0000000")!, decimals: 6)
      == BigUInt(250_000_000))
    #expect(try AmountHelpers.toBaseUnits(amount: Decimal(string: "0.0000000")!, decimals: 6)
      == BigUInt(0))
  }

  /// `BigUInt` is unbounded but the ABI slot it lands in is not, and the encoder would truncate a
  /// larger value into a completely different allowance.
  @Test("an amount above uint256 max is rejected")
  func aboveUInt256MaxRejected() {
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: Decimal(string: "1e60")!, decimals: 18)
    }
  }

  @Test("zero converts to zero base units")
  func zeroConvertsToZero() throws {
    let baseUnits = try AmountHelpers.toBaseUnits(amount: 0, decimals: 18)
    #expect(baseUnits == BigUInt(0))
  }

  @Test("negative amount throws instead of trapping")
  func negativeAmountThrows() {
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: -1, decimals: 18)
    }
  }

  @Test("NaN amount throws invalidAmount instead of converting")
  func nanAmountThrows() {
    // Double.nan.asDecimal surfaces as Decimal.nan; it must never reach base units as 0.
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: Double.nan.asDecimal, decimals: 18)
    }
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: Decimal.nan, decimals: 18)
    }
  }

  @Test("out-of-range decimals throw instead of trapping the Int16 conversion")
  func absurdDecimalsThrow() throws {
    // `Int16(decimals)` in the scaling step traps on overflow — a process crash, not an error —
    // and `decimals` can come from a contract's own `decimals()` read.
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: 1, decimals: 40_000)
    }
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: 1, decimals: -1)
    }
    // The bounds themselves stay usable.
    #expect(try AmountHelpers.toBaseUnits(amount: 1, decimals: 0) == BigUInt(1))
    #expect(try AmountHelpers.toBaseUnits(amount: 0, decimals: 77) == BigUInt(0))
  }

  @Test("toHexString encodes large wei without trapping")
  func toHexStringDoesNotTrapOnLargeWei() {
    // 1e19 > Int64.max, so the old String(Int(self), radix: 16) trapped. 1e19 is an exact Double;
    // build the expected from a radix-10 string (the bare literal would overflow Int at compile time).
    let expected = "0x" + String(BigUInt("10000000000000000000", radix: 10)!, radix: 16)
    #expect((1e19).toHexString == expected)
    #expect((0.0).toHexString == "0x0")
  }
}
