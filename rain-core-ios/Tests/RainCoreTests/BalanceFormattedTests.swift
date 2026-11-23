import Testing
import Foundation
import Web3
@testable import RainCore

/// Pins the display normalization of `Balance.formatted`: plain notation with trailing
/// fractional zeros trimmed, so both platforms print the same string for the same balance.
@Suite("Balance.formatted")
struct BalanceFormattedTests {

  private func balance(raw: BigUInt, decimals: Int) -> Balance {
    Balance(token: .native, chainId: 1, rawAmount: raw, decimals: decimals)
  }

  @Test("a whole-number amount drops the fractional part entirely")
  func wholeNumber() {
    #expect(balance(raw: BigUInt(1_000_000_000_000_000_000), decimals: 18).formatted == "1")
    #expect(balance(raw: BigUInt(25_000_000), decimals: 6).formatted == "25")
  }

  @Test("trailing fractional zeros are trimmed")
  func trailingZerosTrimmed() {
    #expect(balance(raw: BigUInt(500), decimals: 3).formatted == "0.5")
    #expect(balance(raw: BigUInt(1_500_000), decimals: 6).formatted == "1.5")
    #expect(balance(raw: BigUInt(2_030_000), decimals: 6).formatted == "2.03")
  }

  @Test("zero formats as 0")
  func zero() {
    #expect(balance(raw: BigUInt(0), decimals: 18).formatted == "0")
    #expect(balance(raw: BigUInt(0), decimals: 0).formatted == "0")
  }

  @Test("small amounts stay in plain notation, never exponent form")
  func plainNotation() {
    #expect(balance(raw: BigUInt(1), decimals: 18).formatted == "0.000000000000000001")
    #expect(balance(raw: BigUInt(1), decimals: 9).formatted == "0.000000001")
  }

  @Test("zero-decimal tokens print the raw integer")
  func zeroDecimals() {
    #expect(balance(raw: BigUInt(42), decimals: 0).formatted == "42")
  }

  @Test("full precision is preserved when every digit is significant")
  func fullPrecision() {
    #expect(balance(raw: BigUInt(1_234_567), decimals: 6).formatted == "1.234567")
  }
}
