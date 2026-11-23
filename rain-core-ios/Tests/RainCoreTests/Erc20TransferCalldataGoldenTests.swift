import Testing
import Foundation
import Web3
@testable import RainCore

/// Cross-platform goldens for the ERC-20 `transfer` calldata sent by `sendToken`.
/// The full hex is pinned byte-for-byte; any change here must land on both platforms.
@Suite("ERC-20 Transfer Calldata Golden")
struct Erc20TransferCalldataGoldenTests {

  private let chainId = 10
  private let recipient = "0x7f5c764cbc14f9669b88837ca1490cca17c31607"
  private let tokenContract = "0x0b2c639c533813f4aa9d7837caf62653d097ff85"
  private let wallet = "0x1111111111111111111111111111111111111111"

  private func transferCalldata(amount: BigUInt) async throws -> String {
    let builder = TransactionBuilderService(
      networkConfigs: [NetworkConfig(chainId: chainId, rpcUrl: "https://mainnet.optimism.io")]
    )
    return try await builder.buildERC20TransferData(
      chainId: chainId,
      contractAddress: tokenContract,
      walletAddress: wallet,
      toAddress: recipient,
      amount: amount
    )
  }

  @Test("transfer calldata is selector plus padded address and amount")
  func goldenTransferCalldata() async throws {
    let data = try await transferCalldata(amount: 1_000_000)

    #expect(data ==
      "0xa9059cbb"
      + "0000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c31607"
      + "00000000000000000000000000000000000000000000000000000000000f4240"
    )
  }

  @Test("decimal amount converts to base units before encoding")
  func decimalAmountConvertsToBaseUnits() async throws {
    // 1.5 USDC at 6 decimals = 1_500_000 base units.
    let baseUnits = try AmountHelpers.toBaseUnits(amount: Decimal(string: "1.5")!, decimals: 6)
    #expect(baseUnits == BigUInt(1_500_000))

    let fromDecimal = try await transferCalldata(amount: baseUnits)
    let fromBaseUnits = try await transferCalldata(amount: 1_500_000)
    #expect(fromDecimal == fromBaseUnits)
  }

  @Test("zero amount encodes an all-zero amount word")
  func zeroAmountCalldata() async throws {
    let data = try await transferCalldata(amount: 0)

    #expect(data ==
      "0xa9059cbb"
      + "0000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c31607"
      + "0000000000000000000000000000000000000000000000000000000000000000"
    )
  }

  @Test("uint256 max encodes an all-ff amount word")
  func maxAmountCalldata() async throws {
    let max = BigUInt(2).power(256) - 1
    let data = try await transferCalldata(amount: max)

    #expect(data ==
      "0xa9059cbb"
      + "0000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c31607"
      + "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    )
  }

  @Test("amount finer than the token is rejected before encoding")
  func overPrecisionAmountRejected() {
    // 7 decimal places on a 6-decimal token must fail, not silently truncate.
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: Decimal(string: "1.2345678")!, decimals: 6)
    }
  }

  @Test("amount at the token's full precision is accepted")
  func fullPrecisionAmountAccepted() throws {
    let baseUnits = try AmountHelpers.toBaseUnits(amount: Decimal(string: "1.234567")!, decimals: 6)
    #expect(baseUnits == BigUInt(1_234_567))
  }

  @Test("negative amount is rejected instead of encoding a huge uint256")
  func negativeAmountRejected() {
    #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      try AmountHelpers.toBaseUnits(amount: Decimal(string: "-1")!, decimals: 6)
    }
  }
}
