import Foundation
import Web3

/// Utility functions for Ethereum data conversion.
public enum EthereumConverter {

  // MARK: - Hex Normalization

  /// Returns the input if it looks like a non-empty `0x`-prefixed hex string;
  /// otherwise returns `"0x0"`. Used by RPC response handlers that want to keep
  /// downstream parsers from worrying about nil / malformed payloads.
  public static func normalizedHexString(_ hex: String?) -> String {
    guard let hex, hex.hasPrefix("0x"), hex.count > 2 else {
      return "0x0"
    }
    return hex
  }

  // MARK: - Hex to Numeric Conversion

  /// Converts a hex-encoded uint256 string to an `Int` (e.g. for ERC-20 `decimals()` responses).
  public static func parseHexToInt(_ hex: String) -> Int {
    let cleanHex = hex.strippingHexPrefix
    guard !cleanHex.isEmpty else { return 0 }
    return Int(cleanHex, radix: 16) ?? 0
  }

  /// Strict decoder for ABI uint values that must fit in a non-negative `Int`.
  ///
  /// The lenient ``parseHexToInt(_:)`` reads a malformed payload as 0, which for a `decimals()`
  /// response is indistinguishable from a real 0-decimal token and silently rescales every amount
  /// derived from it.
  public static func parseHexToIntStrict(_ hex: String) throws -> Int {
    let value = try parseHexToBigUIntStrict(hex)
    guard let narrowed = Int(exactly: value) else {
      throw RainError.internalError(
        details: "Hex value does not fit in a non-negative Int: \(hex)"
      )
    }
    return narrowed
  }

  /// Decodes an ABI-encoded string returned by `eth_call` (e.g. from ERC-20 `symbol()`).
  ///
  /// ABI string layout (each slot = 32 bytes = 64 hex chars):
  ///   slot 0 — offset to data (usually 0x20)
  ///   slot 1 — byte length of string
  ///   slot 2+ — UTF-8 string bytes, right-padded to 32-byte boundary
  public static func parseHexToString(_ hex: String) -> String? {
    let cleanHex = hex.strippingHexPrefix
    guard cleanHex.count >= 128 else { return nil }

    let lengthHex = String(cleanHex.dropFirst(64).prefix(64))
    guard let byteLength = Int(lengthHex, radix: 16), byteLength > 0,
          byteLength <= (cleanHex.count - 128) / 2 else { return nil }

    let dataHex = String(cleanHex.dropFirst(128).prefix(byteLength * 2))
    guard dataHex.count == byteLength * 2 else { return nil }

    var bytes = [UInt8]()
    bytes.reserveCapacity(byteLength)
    var index = dataHex.startIndex
    while index < dataHex.endIndex {
      let next = dataHex.index(index, offsetBy: 2)
      if let byte = UInt8(dataHex[index..<next], radix: 16) { bytes.append(byte) }
      index = next
    }
    return String(bytes: bytes, encoding: .utf8)
  }

  /// Converts a hex-encoded uint256 string (e.g. from `eth_call`) to a human-readable `Decimal`
  /// using token decimals.
  ///
  /// Uses `NSDecimalNumber` for safe handling of the full uint256 range; the result never passes
  /// through binary floating point.
  ///
  /// - Parameters:
  ///   - hex: Hex string with or without `0x` prefix (e.g. `"0x0de0b6b3a7640000"`).
  ///   - decimals: Number of decimal places the token uses (e.g. 6 for USDC, 18 for ETH).
  /// - Returns: Human-readable amount as `Decimal` (e.g. `1.0` for 1 ETH).
  public static func parseHexToDecimal(_ hex: String, decimals: Int) -> Decimal {
    baseUnitsToDecimal(BigUInt(hex.strippingHexPrefix, radix: 16) ?? 0, decimals: decimals)
  }

  /// Strict counterpart of ``parseHexToDecimal(_:decimals:)`` for money paths: converts a
  /// hex-encoded uint256 RPC payload to a human-readable `Decimal`, throwing on malformed input
  /// instead of collapsing it to a silent zero.
  ///
  /// - Throws: `RainError.internalError` when `hex` is empty (`""` or a bare `"0x"`) or
  ///   contains non-hex characters. `"0x0"` parses to zero as usual.
  public static func parseHexToDecimalStrict(_ hex: String, decimals: Int) throws -> Decimal {
    baseUnitsToDecimal(try parseHexToBigUIntStrict(hex), decimals: decimals)
  }

  /// Deprecated. Use ``parseHexToDecimal(_:decimals:)``; this variant collapses to a lossy `Double`.
  @available(*, deprecated, message: "Use parseHexToDecimal(_:decimals:): Double loses precision above 2^53 base units.")
  public static func parseHexToDouble(_ hex: String, decimals: Int) -> Double {
    NSDecimalNumber(decimal: parseHexToDecimal(hex, decimals: decimals)).doubleValue
  }

  /// Converts an exact base-unit `BigUInt` to a human-readable `Decimal` (`value / 10^decimals`).
  ///
  /// The inverse of ``decimalStringToBigUInt(_:decimals:)``. The division happens on
  /// `NSDecimalNumber`, so the result never passes through binary floating point.
  public static func baseUnitsToDecimal(_ value: BigUInt, decimals: Int) -> Decimal {
    let raw = NSDecimalNumber(string: value.description)
    let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(decimals), isNegative: false)
    return raw.dividing(by: divisor).decimalValue
  }

  /// Converts a hex-encoded uint256 string to a `BigUInt`, collapsing malformed input to `0`.
  ///
  /// Deprecated for exactly that reason: on a money path the silent zero turns a garbage RPC
  /// payload into a zero balance or fee. Use ``parseHexToBigUIntStrict(_:)``, which throws
  /// instead.
  @available(*, deprecated, message: "Use parseHexToBigUIntStrict(_:): this variant silently turns malformed hex into 0.")
  public static func parseHexToBigUInt(_ hex: String) -> BigUInt {
    BigUInt(hex.strippingHexPrefix, radix: 16) ?? 0
  }

  /// Converts a hex-encoded uint256 string to an exact `BigUInt` (no precision loss), throwing
  /// on malformed input.
  ///
  /// Used for values read directly from chain (`eth_getBalance`, `eth_call balanceOf`, gas
  /// reads), where the raw base-unit value must be preserved and a garbage RPC payload must
  /// surface as an error rather than a silent zero.
  ///
  /// - Throws: `RainError.internalError` when `hex` is empty (`""` or a bare `"0x"`) or
  ///   contains non-hex characters. `"0x0"` parses to zero as usual.
  public static func parseHexToBigUIntStrict(_ hex: String) throws -> BigUInt {
    let cleanHex = hex.strippingHexPrefix
    guard !cleanHex.isEmpty, let value = BigUInt(cleanHex, radix: 16) else {
      throw RainError.internalError(details: "Malformed hex payload: \(hex)")
    }
    return value
  }

  /// Reconstructs an exact base-unit `BigUInt` from a human-readable decimal string.
  ///
  /// The inverse of `parseHexToDecimal`: multiplies by `10^decimals` and truncates any
  /// remaining fractional part. Used where a provider only exposes a formatted decimal
  /// balance (e.g. Portal's `getAssets`, Turnkey's supported-chain API) rather than raw hex.
  public static func decimalStringToBigUInt(_ decimalString: String?, decimals: Int) -> BigUInt {
    guard let decimalString, !decimalString.isEmpty else { return 0 }

    let value = NSDecimalNumber(string: decimalString)
    guard !value.doubleValue.isNaN else { return 0 }

    let multiplier = NSDecimalNumber(mantissa: 1, exponent: Int16(decimals), isNegative: false)
    let roundDown = NSDecimalNumberHandler(
      roundingMode: .down,
      scale: 0,
      raiseOnExactness: false,
      raiseOnOverflow: false,
      raiseOnUnderflow: false,
      raiseOnDivideByZero: false
    )
    let baseUnits = value.multiplying(by: multiplier, withBehavior: roundDown)
    guard baseUnits.compare(NSDecimalNumber.zero) == .orderedDescending else { return 0 }

    return BigUInt(baseUnits.stringValue) ?? 0
  }
}
