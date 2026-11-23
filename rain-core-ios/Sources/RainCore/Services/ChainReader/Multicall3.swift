import Foundation

/// ABI encoding/decoding for the [Multicall3](https://www.multicall3.com) contract,
/// limited to the functions the SDK actually uses: `aggregate3`, `getEthBalance`, and
/// ERC-20 `balanceOf` (encoded against a token contract, not Multicall3 itself).
///
/// Pure functions — no I/O — so unit tests can lock in calldata against fixtures.
public enum Multicall3 {
  /// Canonical Multicall3 deployment address (https://www.multicall3.com), deployed at the
  /// same address on most major EVM chains. Per-chain addresses (zkSync Era differs) live in
  /// `Multicall3+Deployments.swift`.
  static let canonicalAddress = "0xcA11bde05977b3631167028862bE2a173976CA11"

  // Multicall3-specific function selectors (first 4 bytes of keccak256(signature)).
  // ERC-20 selectors live in `ERC20Selectors`.
  private static let aggregate3Selector = "82ad56cb"   // aggregate3((address,bool,bytes)[])
  private static let getEthBalanceSelector = "4d2301cc" // getEthBalance(address)

  /// One entry in an `aggregate3` batch.
  struct Call3 {
    /// Target contract address (the token contract for `balanceOf`, or `canonicalAddress` for `getEthBalance`).
    let target: String
    /// If true, a revert in this individual call doesn't fail the whole batch.
    let allowFailure: Bool
    /// Pre-encoded calldata (hex string, with or without `0x` prefix).
    let callData: String
  }

  /// One entry in the `aggregate3` response.
  struct Result {
    let success: Bool
    /// Hex-encoded return data, with `0x` prefix. Empty (`"0x"`) when the call reverted with no return data.
    let returnData: String
  }

  /// Encodes calldata for `aggregate3((address,bool,bytes)[])`.
  /// Returns a hex string with the `0x` prefix, suitable as the `data` field of `eth_call`.
  static func encodeAggregate3(_ calls: [Call3]) -> String {
    var out = "0x" + aggregate3Selector
    // Outer ABI layout for a single dynamic argument:
    //   [0x20 offset to array][array body...]
    out += hex32(32)
    // Array body: [length][offset_1]...[offset_N][tuple_1]...[tuple_N]
    out += hex32(calls.count)

    // Each Call3 tuple is dynamic (contains `bytes`), so the array stores offsets
    // to each tuple's body. Offsets are measured from the start of the array body
    // (i.e. the slot containing `length` is not included).
    var offsets: [Int] = []
    var bodies: [String] = []
    // Offsets are measured from the start of the array body (the position immediately
    // after the length slot). The offsets table itself sits at positions 0..32*N within
    // that body, so the first tuple begins at offset = 32*N.
    var runningOffset = 32 * calls.count

    for call in calls {
      offsets.append(runningOffset)
      let callDataLenBytes = hexByteCount(call.callData)
      let paddedBytes = ((callDataLenBytes + 31) / 32) * 32
      // Tuple body layout:
      //   [target(32)][allowFailure(32)][callData_offset(=0x60)(32)][callData_length(32)][callData_padded(paddedBytes)]
      let bodySize = 96 + 32 + paddedBytes
      runningOffset += bodySize

      var body = ""
      body += hex32Address(call.target)
      body += hex32(call.allowFailure ? 1 : 0)
      body += hex32(96)
      body += hex32(callDataLenBytes)
      body += rightPad32(call.callData.strippingHexPrefix)
      bodies.append(body)
    }

    for offset in offsets {
      out += hex32(offset)
    }
    for body in bodies {
      out += body
    }
    return out
  }

  /// Decodes the return value of `aggregate3` — an array of `(bool, bytes)`.
  /// Throws `RainError.internalError` on a malformed payload.
  static func decodeAggregate3Result(hex: String) throws -> [Result] {
    let bytes = try decodeHex(hex)
    // Layout: [0x20 offset to array][array body...]
    // Array body: [length][offset_1]...[offset_N][tuple_1]...[tuple_N]
    guard bytes.count >= 64 else {
      throw RainError.internalError(details: "Multicall3 result too short (<64 bytes)")
    }
    let count = parseBE(bytes[32..<64])
    let arrayBodyStart = 64
    let offsetsTableEnd = arrayBodyStart + 32 * count
    guard bytes.count >= offsetsTableEnd else {
      throw RainError.internalError(details: "Multicall3 result truncated at offsets table")
    }

    var results: [Result] = []
    results.reserveCapacity(count)
    for i in 0..<count {
      let offsetSlot = arrayBodyStart + 32 * i
      let tupleOffset = arrayBodyStart + parseBE(bytes[offsetSlot..<offsetSlot+32])
      // Each tuple: [success(32)][returnData_offset(=0x40)(32)][returnData_length(32)][returnData_padded]
      guard bytes.count >= tupleOffset + 96 else {
        throw RainError.internalError(details: "Multicall3 tuple #\(i) truncated")
      }
      let success = bytes[tupleOffset + 31] == 1
      let dataLen = parseBE(bytes[tupleOffset+64..<tupleOffset+96])
      let dataStart = tupleOffset + 96
      let dataEnd = dataStart + dataLen
      guard bytes.count >= dataEnd else {
        throw RainError.internalError(details: "Multicall3 tuple #\(i) returnData truncated")
      }
      let returnDataBytes = bytes[dataStart..<dataEnd]
      let dataHex = "0x" + returnDataBytes.map { String(format: "%02x", $0) }.joined()
      results.append(Result(success: success, returnData: dataHex))
    }
    return results
  }

  /// Encodes calldata for `getEthBalance(address)` — the Multicall3 helper that returns
  /// the native balance, so native + ERC-20 can ride in one batch.
  static func encodeGetEthBalance(address: String) -> String {
    "0x" + getEthBalanceSelector + hex32Address(address)
  }

  /// Encodes calldata for ERC-20 `balanceOf(address)`.
  public static func encodeBalanceOf(address: String) -> String {
    "0x" + ERC20Selectors.balanceOf + hex32Address(address)
  }

  // MARK: - Hex helpers

  private static func hexByteCount(_ s: String) -> Int {
    s.strippingHexPrefix.count / 2
  }

  private static func hex32(_ value: Int) -> String {
    let h = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 64 - h.count)) + h
  }

  /// Left-pads a 20-byte address to 32 bytes (64 hex chars).
  private static func hex32Address(_ address: String) -> String {
    let clean = address.strippingHexPrefix.lowercased()
    return String(repeating: "0", count: max(0, 64 - clean.count)) + clean
  }

  /// Right-pads a hex string with zeros so its byte length is a multiple of 32.
  /// Empty input returns empty (no padding needed for a zero-length `bytes`).
  private static func rightPad32(_ hex: String) -> String {
    let chars = hex.count
    guard chars > 0 else { return "" }
    let mod = chars % 64
    let padChars = mod == 0 ? 0 : 64 - mod
    return hex + String(repeating: "0", count: padChars)
  }

  private static func decodeHex(_ hex: String) throws -> [UInt8] {
    let clean = hex.strippingHexPrefix
    guard clean.count.isMultiple(of: 2) else {
      throw RainError.internalError(details: "Multicall3 result has odd hex length")
    }
    var bytes = [UInt8]()
    bytes.reserveCapacity(clean.count / 2)
    var idx = clean.startIndex
    while idx < clean.endIndex {
      let next = clean.index(idx, offsetBy: 2)
      guard let byte = UInt8(clean[idx..<next], radix: 16) else {
        throw RainError.internalError(details: "Multicall3 result contains invalid hex byte")
      }
      bytes.append(byte)
      idx = next
    }
    return bytes
  }

  /// Parses a big-endian byte slice as `Int`. The values we read (counts, offsets,
  /// lengths) are always < 2^31 in practice for any realistic batch.
  private static func parseBE(_ slice: ArraySlice<UInt8>) -> Int {
    var v = 0
    for b in slice { v = (v << 8) | Int(b) }
    return v
  }
}
