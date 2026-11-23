import Foundation
import Web3

/// Hand-rolled ABI encoding for the collateral controller's `withdrawAsset` call.
///
/// Boilertalk's ABI encoder cannot canonically encode this signature: its dynamic-array path
/// length-prefixes fixed-size elements (breaking `bytes32[]`) and omits the per-element offset
/// words (breaking `bytes[]`). The layout below is standard ABI, pinned byte-for-byte by
/// `WithdrawCalldataGoldenTests`, whose fixture is shared with the Android SDK.
enum WithdrawAssetCalldata {

  /// keccak256("withdrawAsset(address,address,uint256,address,uint256,bytes32,bytes,bytes32[],bytes[],bool)")[0..<4].
  /// Pinned rather than computed — the golden test fails if the signature ever drifts.
  private static let selector = "4b268241"

  /// Encodes the full calldata, `0x`-prefixed. `directTransfer` (the trailing bool) is always
  /// true, matching the previous encoder's constant.
  static func encode(_ parameter: WithdrawAssetParameter) -> String {
    // Tails for the three dynamic arguments, in argument order.
    let executorSignatureTail = dynamicBytes(parameter.executorSignature)
    let adminSaltsTail = bytes32Array([parameter.walletSalt])
    let adminSignaturesTail = bytesArray([parameter.walletSignature])

    // Head offsets are byte distances from the start of the arguments (after the selector).
    let headBytes = 10 * 32
    let executorSignatureOffset = headBytes
    let adminSaltsOffset = executorSignatureOffset + executorSignatureTail.count / 2
    let adminSignaturesOffset = adminSaltsOffset + adminSaltsTail.count / 2

    let head =
      word(address: parameter.proxyAddress)
      + word(address: parameter.tokenAddress)
      + word(uint: parameter.amount)
      + word(address: parameter.recipientAddress)
      + word(uint: parameter.expiryAt)
      + hex(parameter.executorSalt) // bytes32: exactly one word, verified by the caller's guard
      + word(uint: BigUInt(executorSignatureOffset))
      + word(uint: BigUInt(adminSaltsOffset))
      + word(uint: BigUInt(adminSignaturesOffset))
      + word(uint: BigUInt(1)) // _directTransfer: always true

    return "0x" + selector + head + executorSignatureTail + adminSaltsTail + adminSignaturesTail
  }

  // MARK: - ABI primitives

  /// `bytes`: length word + contents right-padded to a 32-byte multiple.
  private static func dynamicBytes(_ data: Data) -> String {
    word(uint: BigUInt(data.count)) + rightPadded(hex(data))
  }

  /// `bytes32[]`: length word + one word per element, no per-element prefixes.
  private static func bytes32Array(_ items: [Data]) -> String {
    word(uint: BigUInt(items.count)) + items.map(hex).joined()
  }

  /// `bytes[]`: length word + per-element offset words (relative to the start of the element
  /// area) + each element's `bytes` encoding.
  private static func bytesArray(_ items: [Data]) -> String {
    var offsets = ""
    var tails = ""
    let elementAreaStart = items.count * 32
    for item in items {
      offsets += word(uint: BigUInt(elementAreaStart + tails.count / 2))
      tails += dynamicBytes(item)
    }
    return word(uint: BigUInt(items.count)) + offsets + tails
  }

  private static func word(address: EthereumAddress) -> String {
    leftPadded(String(address.hex(eip55: false).dropFirst(2)))
  }

  private static func word(uint value: BigUInt) -> String {
    leftPadded(String(value, radix: 16))
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func leftPadded(_ hex: String) -> String {
    hex.count >= 64 ? hex : String(repeating: "0", count: 64 - hex.count) + hex
  }

  private static func rightPadded(_ hex: String) -> String {
    let remainder = hex.count % 64
    return remainder == 0 ? hex : hex + String(repeating: "0", count: 64 - remainder)
  }
}
