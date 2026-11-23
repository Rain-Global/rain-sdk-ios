import Testing
import Foundation
@testable import RainCore

/// Cross-platform golden for `withdrawAsset` calldata.
///
/// The expected hex is pinned byte-for-byte and the identical literal is asserted by
/// the same fixtures. Substring assertions would hide argument
/// reordering, so this pins the whole encoding. Any change here must land on both platforms.
@Suite("Withdraw Calldata Golden")
struct WithdrawCalldataGoldenTests {

  @Test("withdrawAsset calldata matches the cross-platform golden")
  func testWithdrawCalldataGolden() throws {
    let addresses = RainWithdrawAddresses(
      proxyAddress: GoldenWithdrawFixture.proxyAddress,
      controllerAddress: GoldenWithdrawFixture.controllerAddress,
      tokenAddress: GoldenWithdrawFixture.tokenAddress,
      recipientAddress: GoldenWithdrawFixture.recipientAddress
    )

    let calldata = try WithdrawalBuilder.buildWithdrawTransactionData(
      builder: TransactionBuilderService(networkConfigs: []),
      addresses: addresses,
      amount: GoldenWithdrawFixture.amount,
      decimals: GoldenWithdrawFixture.decimals,
      executorSignature: RainAdminSignature(
        salt: GoldenWithdrawFixture.executorSaltBase64,
        signature: GoldenWithdrawFixture.executorSignatureHex,
        expiresAt: GoldenWithdrawFixture.expiresAt
      ),
      walletSalt: GoldenWithdrawFixture.walletSalt,
      walletSignature: GoldenWithdrawFixture.walletSignatureHex
    )

    #expect(calldata == GoldenWithdrawFixture.expectedCalldata)
  }
}

/// The pinned inputs and output. Held stable so
/// the two encoders are provably byte-compatible.
enum GoldenWithdrawFixture {
  static let proxyAddress = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
  static let controllerAddress = "0x5555555555555555555555555555555555555555"
  static let tokenAddress = "0x9876543210987654321098765432109876543210"
  static let recipientAddress = "0xfedcbafedcbafedcbafedcbafedcbafedcbafedc"

  static let amount: Decimal = 100.5
  static let decimals = 6
  static let expiresAt = "1735689600"

  /// Rain's executor-publisher salt, base64 as the Rain API returns it (32 x 0x11).
  static let executorSaltBase64 = "ERERERERERERERERERERERERERERERERERERERERERE="

  /// Rain's executor-publisher signature (65 x 0x42).
  static let executorSignatureHex = "0x"
    + "4242424242424242424242424242424242424242424242424242424242424242"
    + "4242424242424242424242424242424242424242424242424242424242424242"
    + "42"

  /// The wallet's own signature (65 x 0xBB), encoded into `_adminSignatures`.
  static let walletSignatureHex = "0x"
    + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    + "bb"

  /// The wallet's own EIP-712 salt (32 x 0xAA), encoded into `_adminSalts`.
  static let walletSalt = Data(repeating: 0xAA, count: 32)

  static let expectedCalldata = "0x4b268241"
    + "000000000000000000000000abcdefabcdefabcdefabcdefabcdefabcdefabcd"
    + "0000000000000000000000009876543210987654321098765432109876543210"
    + "0000000000000000000000000000000000000000000000000000000005fd8220"
    + "000000000000000000000000fedcbafedcbafedcbafedcbafedcbafedcbafedc"
    + "0000000000000000000000000000000000000000000000000000000067748580"
    + "1111111111111111111111111111111111111111111111111111111111111111"
    + "0000000000000000000000000000000000000000000000000000000000000140"
    + "00000000000000000000000000000000000000000000000000000000000001c0"
    + "0000000000000000000000000000000000000000000000000000000000000200"
    + "0000000000000000000000000000000000000000000000000000000000000001"
    + "0000000000000000000000000000000000000000000000000000000000000041"
    + "4242424242424242424242424242424242424242424242424242424242424242"
    + "4242424242424242424242424242424242424242424242424242424242424242"
    + "4200000000000000000000000000000000000000000000000000000000000000"
    + "0000000000000000000000000000000000000000000000000000000000000001"
    + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    + "0000000000000000000000000000000000000000000000000000000000000001"
    + "0000000000000000000000000000000000000000000000000000000000000020"
    + "0000000000000000000000000000000000000000000000000000000000000041"
    + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    + "bb00000000000000000000000000000000000000000000000000000000000000"
}
