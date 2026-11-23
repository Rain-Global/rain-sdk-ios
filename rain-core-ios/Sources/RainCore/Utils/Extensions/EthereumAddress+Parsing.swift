import Foundation
import Web3

extension EthereumAddress {
  /// Parses a user- or host-supplied address string, validating length, prefix, hex content and
  /// — for mixed-case input — the EIP-55 checksum.
  ///
  /// The checksum rule matches the old parser's: a mixed-case address carries a checksum in its
  /// letter casing, and accepting it unverified would let a mistyped character be silently
  /// re-checksummed into a different, valid-looking address later (nothing downstream could
  /// tell). All-lowercase and all-uppercase hex carries no checksum and stays lenient. The
  /// `0x` prefix is required, also matching the old parser. The case analysis runs on the hex
  /// part only — the lowercase `x` in the prefix must not make an all-uppercase address count
  /// as mixed case.
  ///
  /// NEVER use the library's `init?(hexString:)` to parse input: that is an ABI-DECODING
  /// initializer expecting a 32-byte ABI word — it drops `count - 40` leading characters and
  /// TRAPS on any string shorter than 40 characters. This wraps the validating `init(hex:eip55:)`
  /// instead, which rejects malformed input by returning nil.
  internal static func parse(_ address: String) -> EthereumAddress? {
    guard address.hasPrefix("0x") else { return nil }
    let hexPart = String(address.dropFirst(2))
    let isMixedCase = hexPart != hexPart.lowercased() && hexPart != hexPart.uppercased()
    return try? EthereumAddress(hex: address, eip55: isMixedCase)
  }
}
