import Foundation

/// Base58 codec using the Bitcoin / Solana alphabet.
///
/// Solana account addresses, blockhashes and transaction signatures are Base58 strings of
/// 32- or 64-byte values. EVM uses hex, so the SDK had no Base58 until Solana support — and
/// neither Foundation nor the SDK's existing dependencies ship one, hence this small,
/// dependency-free implementation.
///
/// Leading zero bytes map to leading `"1"` characters (and back), matching the reference
/// implementations. Uses the canonical byte-array base-conversion algorithm so it needs no
/// big-integer type.
@_spi(RainAdapter) public enum Base58 {
  private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

  /// Reverse lookup: Base58 character -> value. Built once from `alphabet`.
  private static let indexes: [Character: Int] = {
    var table: [Character: Int] = [:]
    for (i, c) in alphabet.enumerated() { table[c] = i }
    return table
  }()

  /// Encodes raw bytes to a Base58 string.
  public static func encode(_ input: [UInt8]) -> String {
    if input.isEmpty { return "" }

    // Count leading zero bytes — each maps to a leading "1".
    var zeros = 0
    while zeros < input.count && input[zeros] == 0 { zeros += 1 }

    // Upper bound on output length: log(256) / log(58) ≈ 1.365.
    let size = (input.count - zeros) * 138 / 100 + 1
    var b58 = [UInt8](repeating: 0, count: size)
    var length = 0

    for i in zeros..<input.count {
      var carry = Int(input[i])
      var j = 0
      var k = size - 1
      while (carry != 0 || j < length) && k >= 0 {
        carry += 256 * Int(b58[k])
        b58[k] = UInt8(carry % 58)
        carry /= 58
        j += 1
        k -= 1
      }
      length = j
    }

    // Skip leading zeros left in the working buffer.
    var it = size - length
    while it < size && b58[it] == 0 { it += 1 }

    var result = String(repeating: "1", count: zeros)
    while it < size {
      result.append(alphabet[Int(b58[it])])
      it += 1
    }
    return result
  }

  /// Decodes a Base58 string to raw bytes. Throws `RainError.internalError` on an
  /// invalid character.
  static func decode(_ input: String) throws -> [UInt8] {
    if input.isEmpty { return [] }

    let chars = Array(input)

    // Count leading "1" characters — each maps to a leading zero byte.
    var zeros = 0
    var idx = 0
    while idx < chars.count && chars[idx] == "1" { zeros += 1; idx += 1 }

    // Upper bound on output length: log(58) / log(256) ≈ 0.733.
    let size = (chars.count - zeros) * 733 / 1000 + 1
    var b256 = [UInt8](repeating: 0, count: size)
    var length = 0

    while idx < chars.count {
      guard let digit = indexes[chars[idx]] else {
        throw RainError.internalError(details: "Invalid Base58 character '\(chars[idx])'")
      }
      var carry = digit
      var j = 0
      var k = size - 1
      while (carry != 0 || j < length) && k >= 0 {
        carry += 58 * Int(b256[k])
        b256[k] = UInt8(carry % 256)
        carry /= 256
        j += 1
        k -= 1
      }
      length = j
      idx += 1
    }

    // Skip leading zeros left in the working buffer.
    var it = size - length
    while it < size && b256[it] == 0 { it += 1 }

    var result = [UInt8](repeating: 0, count: zeros)
    if it < size {
      result.append(contentsOf: b256[it...])
    }
    return result
  }
}
