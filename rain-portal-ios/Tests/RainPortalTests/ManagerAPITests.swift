import Testing
import Foundation
import PortalSwift
@testable import RainCore
@testable import RainPortal

/// Public-API tests for wallet-agnostic building. In the modular API `buildTransactionParameters`
/// lives on ``RainSdk``. The removed `setWalletProvider(_:)` and `reset()` lifecycle methods no
/// longer exist, so those tests are dropped.
@Suite("Manager Public API Tests")
struct ManagerAPITests {

  // MARK: - buildTransactionParameters

  @Test("buildTransactionParameters returns a Rain-owned RainTransactionParameters; wires from, to, data; value is zero")
  func testComposeTransactionParameters() throws {
    let rain = try TestManagers.rainSdk()

    // Rain-owned return type, not Portal's `ETHTransactionParam`.
    let params: RainTransactionParameters = rain.buildTransactionParameters(
      walletAddress: TestFixtures.walletAddress,
      contractAddress: TestFixtures.contractAddress,
      transactionData: "0xdeadbeef"
    )

    #expect(params.from == TestFixtures.walletAddress)
    #expect(params.to == TestFixtures.contractAddress)
    #expect(params.data == "0xdeadbeef")
    // value should be zero wei hex
    #expect(params.value == "0x0")
  }

  // Dropped: "setWalletProvider(nil) clears the provider", "setWalletProvider replaces an existing
  // provider", "reset() clears wallet provider", and "reset() is idempotent" — the
  // setWalletProvider / reset lifecycle API was removed in the modular refactor.
}
