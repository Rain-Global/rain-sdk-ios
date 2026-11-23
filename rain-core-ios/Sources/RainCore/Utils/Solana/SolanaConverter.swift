import Foundation
import Web3

/// SOL <-> lamports conversion, mirroring `EthereumConverter`'s role for wei.
/// 1 SOL = 1e9 lamports; SOL therefore has 9 decimals (vs 18 for EVM native currencies).
@_spi(RainAdapter) public enum SolanaConverter {
  static let solDecimals = 9
  static let lamportsPerSol: UInt64 = 1_000_000_000

  /// Formats raw lamports as a precise SOL `Decimal` (`lamports / 1e9`).
  @_spi(RainAdapter) public static func lamportsToSol(_ lamports: BigUInt) -> Decimal {
    let raw = NSDecimalNumber(string: lamports.description)
    let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(solDecimals), isNegative: false)
    return raw.dividing(by: divisor).decimalValue
  }

  /// `UInt64` overload (e.g. lamports decoded from a transaction), avoiding a `BigUInt(UInt64)`
  /// conversion that is ambiguous once BigInt is in module scope.
  @_spi(RainAdapter) public static func lamportsToSol(_ lamports: UInt64) -> Decimal {
    let raw = NSDecimalNumber(value: lamports)
    let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(solDecimals), isNegative: false)
    return raw.dividing(by: divisor).decimalValue
  }

}
