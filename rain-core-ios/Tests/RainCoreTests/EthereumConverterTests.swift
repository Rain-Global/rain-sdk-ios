import Testing
import Foundation
import Web3
@testable import RainCore

/// Strict hex parsing for money paths: malformed RPC payloads must throw instead of collapsing
/// to a silent zero balance or fee.
@Suite("EthereumConverter Tests")
struct EthereumConverterTests {

  @Test("parseHexToBigUIntStrict parses well-formed payloads exactly")
  func strictParsesWellFormedHex() throws {
    #expect(try EthereumConverter.parseHexToBigUIntStrict("0x0") == 0)
    // 1 ETH in wei.
    #expect(
      try EthereumConverter.parseHexToBigUIntStrict("0x0de0b6b3a7640000")
        == BigUInt(1_000_000_000_000_000_000)
    )
  }

  @Test(
    "parseHexToBigUIntStrict throws internalError on malformed or empty payloads",
    arguments: ["not-hex", "0xZZ", "", "0x"]
  )
  func strictThrowsOnMalformedHex(hex: String) {
    #expect(throws: RainError.internalError(details: "")) {
      _ = try EthereumConverter.parseHexToBigUIntStrict(hex)
    }
  }

  @Test("parseHexToDecimalStrict scales by token decimals and throws on malformed input")
  func strictDecimalScalesAndThrows() throws {
    #expect(try EthereumConverter.parseHexToDecimalStrict("0x0de0b6b3a7640000", decimals: 18) == 1)
    #expect(try EthereumConverter.parseHexToDecimalStrict("0x0", decimals: 6) == 0)
    #expect(throws: RainError.internalError(details: "")) {
      _ = try EthereumConverter.parseHexToDecimalStrict("0xZZ", decimals: 18)
    }
  }

  @Test("parseHexToString returns nil instead of trapping on a length longer than the payload")
  func stringRejectsOversizedLength() {
    let offset = String(repeating: "0", count: 62) + "20"
    let hugeLength = "7" + String(repeating: "f", count: 15)
    let length = String(repeating: "0", count: 48) + hugeLength
    let data = String(repeating: "41", count: 32)
    #expect(
      EthereumConverter.parseHexToString("0x" + offset + length + data) == nil,
      "a token contract controls this length, so a junk value must not overflow byteLength * 2"
    )
    let usdc = "0x" + offset + String(repeating: "0", count: 63) + "4" + "55534443" + String(repeating: "0", count: 56)
    #expect(EthereumConverter.parseHexToString(usdc) == "USDC")
  }
}
