import Testing
import Foundation
import Web3
@testable import RainCore

/// Cross-platform goldens for the ERC-20 `approve` calldata sent by `approveTokenAllowance`.
/// The full hex is pinned byte-for-byte; any change here must land on both platforms.
@Suite("ERC-20 Approve Calldata Golden")
struct Erc20ApproveCalldataGoldenTests {

  private let chainId = RainChain.baseSepolia
  /// A collateral contract — the Auth Pull spender.
  private let spender = "0x5a6E6b0d5Ea051CfFF9b3dcC2Aa8Dac226458f29"
  private let tokenContract = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  private let wallet = "0x1111111111111111111111111111111111111111"

  private let paddedSpender = "0000000000000000000000005a6e6b0d5ea051cfff9b3dcc2aa8dac226458f29"

  private func approveCalldata(amount: BigUInt) async throws -> String {
    let builder = TransactionBuilderService(
      networkConfigs: [NetworkConfig(chainId: chainId, rpcUrl: "https://sepolia.base.org")]
    )
    return try await builder.buildERC20ApproveData(
      chainId: chainId,
      contractAddress: tokenContract,
      walletAddress: wallet,
      spender: spender,
      amount: amount
    )
  }

  @Test("approve calldata is selector plus padded spender and amount")
  func goldenApproveCalldata() async throws {
    // 250 USDC at 6 decimals = 250_000_000 base units.
    let data = try await approveCalldata(amount: 250_000_000)

    #expect(data ==
      "0x095ea7b3"
      + paddedSpender
      + "000000000000000000000000000000000000000000000000000000000ee6b280"
    )
  }

  @Test("an unlimited approval encodes uint256 max")
  func goldenUnlimitedApprovalCalldata() async throws {
    let data = try await approveCalldata(amount: RainTokenAllowance.unlimitedRawAmount)

    #expect(data ==
      "0x095ea7b3"
      + paddedSpender
      + "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    )
  }

  @Test("a revoke encodes an all-zero amount word")
  func goldenRevokeCalldata() async throws {
    let data = try await approveCalldata(amount: 0)

    #expect(data ==
      "0x095ea7b3"
      + paddedSpender
      + "0000000000000000000000000000000000000000000000000000000000000000"
    )
  }

  @Test("decimal amount converts to base units before encoding")
  func decimalAmountConvertsToBaseUnits() async throws {
    let baseUnits = try AmountHelpers.toBaseUnits(amount: Decimal(string: "1.5")!, decimals: 6)
    #expect(baseUnits == BigUInt(1_500_000))

    let fromDecimal = try await approveCalldata(amount: baseUnits)
    let fromBaseUnits = try await approveCalldata(amount: 1_500_000)
    #expect(fromDecimal == fromBaseUnits)
  }

  @Test("an amount past uint256 max is rejected before encoding")
  func aboveUint256MaxRejected() async {
    // The ABI word would silently truncate it into a completely different allowance.
    await #expect(throws: RainError.invalidAmount(amount: "", reason: "")) {
      _ = try await approveCalldata(amount: RainTokenAllowance.unlimitedRawAmount + 1)
    }
  }

  @Test("unlimitedRawAmount is exactly uint256 max")
  func unlimitedRawAmountIsUint256Max() {
    #expect(RainTokenAllowance.unlimitedRawAmount == BigUInt(2).power(256) - 1)
    #expect(
      RainTokenAllowance.unlimitedRawAmount.description ==
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"
    )
  }

  @Test("the allowance read selector is allowance(address,address)")
  func allowanceSelectorPinned() {
    #expect(ERC20Selectors.allowance == "dd62ed3e")
    #expect(ERC20Selectors.approve == "095ea7b3")
  }

  @Test("allowance calldata is selector plus padded owner and spender")
  func goldenAllowanceCalldata() {
    let data = ERC20Calldata.allowance(owner: wallet, spender: spender)

    #expect(data ==
      "0xdd62ed3e"
      + "0000000000000000000000001111111111111111111111111111111111111111"
      + paddedSpender
    )
  }
}
