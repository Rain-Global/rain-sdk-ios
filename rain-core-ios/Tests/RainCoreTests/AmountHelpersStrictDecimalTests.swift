import Testing
import Foundation
@testable import RainCore

/// Pins the strict decimal contract the producers rely on when scaling a provider-supplied amount.
/// Replaces the old `WalletTransaction` Codable suite: the contract was never about serialization,
/// it was about refusing to half-parse a non-numeric string.
@Suite("AmountHelpers.strictDecimal Tests")
struct AmountHelpersStrictDecimalTests {

  @Test("parses a full-precision decimal exactly")
  func testFullPrecision() throws {
    let parsed = try #require(AmountHelpers.strictDecimal(from: "1.123456789012345678"))
    #expect(parsed == Decimal(string: "1.123456789012345678"))
  }

  @Test("accepts sign and exponent forms")
  func testSignAndExponent() {
    #expect(AmountHelpers.strictDecimal(from: "-1.5") == Decimal(string: "-1.5"))
    #expect(AmountHelpers.strictDecimal(from: "+2") == Decimal(2))
    #expect(AmountHelpers.strictDecimal(from: "1e3") == Decimal(1000))
    #expect(AmountHelpers.strictDecimal(from: "  42  ") == Decimal(42))
  }

  /// The regression this exists for: `Decimal(string:)` takes the longest valid prefix, so a hex
  /// amount silently became zero. Both assertions together document the old behaviour and the fix.
  @Test("rejects hex instead of silently parsing its prefix as zero")
  func testRejectsHex() {
    #expect(Decimal(string: "0x10") == Decimal(0))
    #expect(AmountHelpers.strictDecimal(from: "0x10") == nil)
  }

  @Test("rejects trailing junk and empty input")
  func testRejectsJunk() {
    #expect(AmountHelpers.strictDecimal(from: "12abc") == nil)
    #expect(AmountHelpers.strictDecimal(from: "") == nil)
    #expect(AmountHelpers.strictDecimal(from: "   ") == nil)
    #expect(AmountHelpers.strictDecimal(from: "1.2.3") == nil)
  }
}
