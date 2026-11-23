import Testing
import Foundation
@testable import RainCore

/// Locks in Multicall3 ABI encoding/decoding against known-good fixtures.
@Suite("Multicall3 Tests")
struct Multicall3Tests {

  private let wallet = "0x1234567890123456789012345678901234567890"

  // MARK: - Calldata helpers

  @Test("encodeBalanceOf produces the canonical balanceOf(address) selector + padded address")
  func testEncodeBalanceOf() {
    let data = Multicall3.encodeBalanceOf(address: wallet)
    // 0x70a08231 + 12 bytes of left-padding zeros + 20 bytes address
    #expect(data == "0x70a08231000000000000000000000000" + "1234567890123456789012345678901234567890")
  }

  @Test("encodeGetEthBalance produces the canonical getEthBalance(address) selector + padded address")
  func testEncodeGetEthBalance() {
    let data = Multicall3.encodeGetEthBalance(address: wallet)
    #expect(data == "0x4d2301cc000000000000000000000000" + "1234567890123456789012345678901234567890")
  }

  @Test("encodeBalanceOf strips 0x prefix and lowercases mixed-case addresses")
  func testEncodeBalanceOfNormalizesAddress() {
    let mixed = "0xABCDEFabcdef00000000000000000000ABCDEFAB"
    let data = Multicall3.encodeBalanceOf(address: mixed)
    #expect(data == "0x70a08231000000000000000000000000" + "abcdefabcdef00000000000000000000abcdefab")
  }

  // MARK: - aggregate3 encoding

  @Test("encodeAggregate3 with a single balanceOf call produces correct ABI layout")
  func testEncodeAggregate3SingleCall() {
    let token = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let call = Multicall3.Call3(
      target: token,
      allowFailure: true,
      callData: Multicall3.encodeBalanceOf(address: wallet)
    )
    let encoded = Multicall3.encodeAggregate3([call])

    // Expected layout:
    //   0x82ad56cb                                                              // selector
    //   0000...0020                                                             // outer array offset
    //   0000...0001                                                             // array length = 1
    //   0000...0040                                                             // offset to tuple #0 (32 + 32 = 64 bytes from arrayBodyStart? actually 32: just length slot)
    // wait — offsets are measured from the start of the *array body*, which is
    // *after* the length slot. So offset_0 = 32 (skip the offsets table which has 1 slot).
    //   ...tuple body...
    let expected = "0x82ad56cb"
      + "0000000000000000000000000000000000000000000000000000000000000020"  // outer offset
      + "0000000000000000000000000000000000000000000000000000000000000001"  // array length
      + "0000000000000000000000000000000000000000000000000000000000000020"  // offset to tuple #0 (= 32, past the 1-slot offsets table)
      // tuple #0:
      + "000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  // target
      + "0000000000000000000000000000000000000000000000000000000000000001"  // allowFailure = true
      + "0000000000000000000000000000000000000000000000000000000000000060"  // callData offset within tuple
      + "0000000000000000000000000000000000000000000000000000000000000024"  // callData length = 36 bytes (selector + 32-byte arg)
      + "70a082310000000000000000000000001234567890123456789012345678901234567890" // selector + padded address
      + "00000000000000000000000000000000000000000000000000000000"           // right-pad to 32-byte multiple
    #expect(encoded == expected)
  }

  @Test("encodeAggregate3 with three calls correctly stacks offsets and bodies")
  func testEncodeAggregate3ThreeCalls() {
    // Mostly exercising the offsets — each tuple has a 36-byte callData = 64-byte padded
    // so each tuple body is 96 (head) + 32 (length slot) + 64 (padded data) = 192 = 0xc0
    let calls: [Multicall3.Call3] = (0..<3).map { i in
      let target = "0x" + String(repeating: String(format: "%02x", 0xa0 + i), count: 20)
      return Multicall3.Call3(
        target: target,
        allowFailure: true,
        callData: Multicall3.encodeBalanceOf(address: wallet)
      )
    }
    let encoded = Multicall3.encodeAggregate3(calls)

    // The first offset is past the 3-slot offsets table: 3 * 32 = 96 = 0x60
    // Subsequent offsets advance by one tuple body each: 0x60 + 0xc0 = 0x120, then 0x1e0
    #expect(encoded.contains("0000000000000000000000000000000000000000000000000000000000000060"))
    #expect(encoded.contains("0000000000000000000000000000000000000000000000000000000000000120"))
    #expect(encoded.contains("00000000000000000000000000000000000000000000000000000000000001e0"))
  }

  // MARK: - aggregate3 decoding

  @Test("decodeAggregate3Result parses a single successful uint256 result")
  func testDecodeAggregate3SingleSuccess() throws {
    // Synthetic response: one tuple, success=true, returnData = uint256(0xdeadbeef)
    let hex = "0x"
      + "0000000000000000000000000000000000000000000000000000000000000020"  // outer offset
      + "0000000000000000000000000000000000000000000000000000000000000001"  // array length
      + "0000000000000000000000000000000000000000000000000000000000000020"  // tuple offset
      + "0000000000000000000000000000000000000000000000000000000000000001"  // success = 1
      + "0000000000000000000000000000000000000000000000000000000000000040"  // returnData offset
      + "0000000000000000000000000000000000000000000000000000000000000020"  // returnData length = 32
      + "00000000000000000000000000000000000000000000000000000000deadbeef"  // returnData

    let results = try Multicall3.decodeAggregate3Result(hex: hex)
    try #require(results.count == 1)
    #expect(results[0].success == true)
    #expect(results[0].returnData == "0x00000000000000000000000000000000000000000000000000000000deadbeef")
  }

  @Test("decodeAggregate3Result handles mixed success/failure inside a batch")
  func testDecodeAggregate3MixedResults() throws {
    // Two tuples: first succeeds with 0x42, second fails with empty returnData.
    let hex = "0x"
      + "0000000000000000000000000000000000000000000000000000000000000020"  // outer offset
      + "0000000000000000000000000000000000000000000000000000000000000002"  // array length = 2
      + "0000000000000000000000000000000000000000000000000000000000000040"  // tuple 0 offset
      + "00000000000000000000000000000000000000000000000000000000000000c0"  // tuple 1 offset
      // tuple 0: success=1, data=0x42
      + "0000000000000000000000000000000000000000000000000000000000000001"
      + "0000000000000000000000000000000000000000000000000000000000000040"
      + "0000000000000000000000000000000000000000000000000000000000000020"
      + "0000000000000000000000000000000000000000000000000000000000000042"
      // tuple 1: success=0, data=empty
      + "0000000000000000000000000000000000000000000000000000000000000000"
      + "0000000000000000000000000000000000000000000000000000000000000040"
      + "0000000000000000000000000000000000000000000000000000000000000000"

    let results = try Multicall3.decodeAggregate3Result(hex: hex)
    try #require(results.count == 2)
    #expect(results[0].success == true)
    #expect(results[0].returnData == "0x0000000000000000000000000000000000000000000000000000000000000042")
    #expect(results[1].success == false)
    #expect(results[1].returnData == "0x")
  }

  @Test("decodeAggregate3Result throws on truncated payload")
  func testDecodeAggregate3Truncated() {
    let hex = "0x" + String(repeating: "00", count: 30) // 30 bytes, less than the 64-byte header
    #expect(throws: RainError.self) {
      _ = try Multicall3.decodeAggregate3Result(hex: hex)
    }
  }

  @Test("deployedChainIds matches every TokenRegistry chain")
  func testDeploymentsMatchTokenRegistry() {
    let registryChainIds = Set(TokenRegistry.tokensByChainId.keys)
    #expect(Multicall3.deployedChainIds == registryChainIds)
  }

  /// zkSync Era cannot host the canonical CREATE2 deployment; every other chain uses it.
  @Test("zkSync Era resolves to its own Multicall3 address, all other chains to the canonical one")
  func testZkSyncEraDeploymentAddress() {
    #expect(Multicall3.address(on: 324) == "0xF9cda624FBC7e059355ce98a31693d299FACd963")
    for (chainId, address) in Multicall3.deployments where chainId != 324 {
      #expect(address == Multicall3.canonicalAddress, "chain \(chainId)")
    }
    #expect(Multicall3.address(on: 11_155_111) == nil)
  }
}
