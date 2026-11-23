import Testing
import Foundation
import Web3
@testable import RainCore

/// `EthereumAddress.parse` gates every address the SDK accepts from hosts and users — withdrawal
/// addresses, sendToken recipients on the Portal and Turnkey adapters, contract addresses.
@Suite("EthereumAddress Parsing")
struct EthereumAddressParsingTests {

  /// The EIP-55 spec's own example address, correctly checksummed.
  private static let checksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
  /// Same address with one letter's casing flipped — a broken checksum.
  private static let wrongChecksum = "0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed"

  @Test("a correctly checksummed mixed-case address parses")
  func validChecksumParses() {
    #expect(EthereumAddress.parse(Self.checksummed) != nil)
  }

  @Test("a mixed-case address with a broken checksum is rejected")
  func wrongChecksumRejected() {
    // A mistyped character in a checksummed address must fail here — accepting it would let
    // `checksummed` re-checksum the WRONG address into fresh, valid-looking casing that nothing
    // downstream can distinguish from the right one.
    #expect(EthereumAddress.parse(Self.wrongChecksum) == nil)
  }

  @Test("all-lowercase and all-uppercase hex carry no checksum and stay lenient")
  func casedButUncheckedFormsParse() {
    #expect(EthereumAddress.parse(Self.checksummed.lowercased()) != nil)
    #expect(EthereumAddress.parse("0x" + Self.checksummed.dropFirst(2).uppercased()) != nil)
  }

  @Test("a 40-char address without the 0x prefix is rejected")
  func missingPrefixRejected() {
    #expect(EthereumAddress.parse(String(Self.checksummed.dropFirst(2))) == nil)
  }

  @Test("malformed input is rejected, never trapped on", arguments: [
    "", "0x", "invalid-address", "0x1234", "0xzz5aAeb6053F3E94C9b9A09f33669435E7Ef1Be",
  ])
  func malformedRejected(input: String) {
    #expect(EthereumAddress.parse(input) == nil)
  }

  @Test("a broken checksum in a withdrawal address surfaces as invalidConfig")
  func brokenChecksumFailsValidation() {
    let addresses = RainWithdrawAddresses(
      proxyAddress: Self.checksummed,
      controllerAddress: Self.checksummed,
      tokenAddress: Self.checksummed,
      recipientAddress: Self.wrongChecksum
    )
    #expect(throws: RainError.self) {
      _ = try addresses.validated()
    }
  }

  @Test("checksumming normalizes a lowercase address to its EIP-55 form")
  func checksumNormalization() throws {
    let normalized = try RainWithdrawAddresses.checksummed(
      Self.checksummed.lowercased(), label: "recipientAddress"
    )
    #expect(normalized == Self.checksummed)
  }
}
