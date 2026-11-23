import Testing
import Foundation
import CoreGraphics
@testable import PortalSwift
@testable import RainCore
@testable import RainPortal

/// Manager-contract tests for wallet info APIs: QR-code generation (provider-independent) and
/// transaction routing. The removed init/lifecycle cases ("throws sdkNotInitialized before
/// initialization" / "when no provider") are dropped — a `RainSdkManager` is always bound to a
/// provider now.
@Suite("Wallet Information Tests")
struct WalletInformationTests {

  // MARK: - getWalletAddress

  @Test("getWalletAddress returns address when provider has one")
  func testGetWalletAddressSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)
    let address = try await manager.getWalletAddress()
    #expect(address == TestFixtures.walletAddress)
  }

  // MARK: - generateAddressQRCode(address: nil) — the wallet's own address

  @Test("generateAddressQRCode(address: nil) returns valid PNG data")
  func testGenerateQRCodeSuccess() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let imageData = try await manager.generateAddressQRCode(address: nil, dimension: 256, backgroundColor: nil, foregroundColor: nil)
    expectPNG(imageData)
  }

  @Test("generateAddressQRCode(address: nil) honors custom dimension")
  func testGenerateQRCodeCustomDimension() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress("0xabcdef1234567890", forNamespace: PortalNamespace.eip155)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let imageData = try await manager.generateAddressQRCode(address: nil, dimension: 128, backgroundColor: nil, foregroundColor: nil)
    expectPNG(imageData)
  }

  @Test("generateAddressQRCode(address: nil) honors custom colors")
  func testGenerateQRCodeCustomColors() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let bg = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    let fg = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let imageData = try await manager.generateAddressQRCode(
      address: nil,
      dimension: 200,
      backgroundColor: bg,
      foregroundColor: fg
    )
    expectPNG(imageData)
  }

  // MARK: - getTransactions

  @Test("getTransactions returns empty list when provider returns no transactions")
  func testGetTransactionsEmpty() async throws {
    let mockPortal = MockPortal()
    mockPortal.setMockAddress(TestFixtures.walletAddress, forNamespace: PortalNamespace.eip155)
    mockPortal.mockFetchedTransactions = []
    let (manager, _, _) = TestManagers.portalManager(portal: mockPortal)

    let list = try await manager.getTransactions(chainId: 1)
    #expect(list.isEmpty)
  }

  @Test("getTransactions forwards pagination/order to the provider and returns its list")
  func testGetTransactionsRoutesToProvider() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    let tx = RainTransaction(
      hash: "0xabc",
      uniqueId: "uid-1",
      blockNumber: "100",
      timestamp: "2024-01-01T00:00:00Z",
      from: "0xfrom",
      to: "0xto",
      value: 1.0,
      category: .external,
      chainId: 1
    )
    stub.transactionsToReturn = [tx]

    let list = try await manager.getTransactions(chainId: 1, limit: 5, offset: 2, order: .ASC)

    #expect(list.count == 1)
    #expect(list[0].hash == "0xabc")
    #expect(stub.getTransactionsCalls.count == 1)
    #expect(stub.getTransactionsCalls[0].chainId == 1)
    #expect(stub.getTransactionsCalls[0].limit == 5)
    #expect(stub.getTransactionsCalls[0].offset == 2)
    #expect(stub.getTransactionsCalls[0].order == .ASC)
  }
}

// MARK: - PNG helper

/// PNG files start with magic bytes 0x89 0x50 0x4E 0x47 ('\x89PNG').
private func expectPNG(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(!data.isEmpty, sourceLocation: sourceLocation)
  #expect(data.count > 100, sourceLocation: sourceLocation)
  #expect(
    data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47,
    sourceLocation: sourceLocation
  )
}
