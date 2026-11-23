import Testing
import Foundation
@testable import RainCore

/// Covers the client's QR surface: `generateAddressQRCode` encodes any address (with `nil` falling
/// back to the wallet's own), (nil encodes the wallet's own address) stays the wallet-address shortcut.
@Suite("QR Code Generation Tests")
struct QRCodeGenerationTests {

  /// PNG file signature — the first eight bytes of every PNG.
  private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

  private func isPNG(_ data: Data) -> Bool {
    data.count > pngMagic.count && Array(data.prefix(pngMagic.count)) == pngMagic
  }

  @Test("Encodes an explicit address as PNG data")
  func encodesExplicitAddress() async throws {
    let (manager, _) = try await TestManagers.stubProviderManager()

    let png = try await manager.generateAddressQRCode(address: TestFixtures.recipientAddress)

    #expect(isPNG(png))
  }

  @Test("A nil address falls back to the wallet address")
  func nilAddressUsesWalletAddress() async throws {
    let (manager, stub) = try await TestManagers.stubProviderManager()
    stub.addressToReturn = TestFixtures.walletAddress

    let fallback = try await manager.generateAddressQRCode(address: String?.none)
    let explicit = try await manager.generateAddressQRCode(address: TestFixtures.walletAddress)

    #expect(fallback == explicit)
  }

  @Test("Different addresses produce different QR codes")
  func differentAddressesDiffer() async throws {
    let (manager, _) = try await TestManagers.stubProviderManager()

    let wallet = try await manager.generateAddressQRCode(address: TestFixtures.walletAddress)
    let recipient = try await manager.generateAddressQRCode(address: TestFixtures.recipientAddress)

    #expect(wallet != recipient)
  }

  @Test("Dimension is honoured")
  func dimensionIsHonoured() async throws {
    let (manager, _) = try await TestManagers.stubProviderManager()

    let small = try await manager.generateAddressQRCode(
      address: TestFixtures.walletAddress,
      dimension: 128,
      backgroundColor: nil,
      foregroundColor: nil
    )
    let large = try await manager.generateAddressQRCode(
      address: TestFixtures.walletAddress,
      dimension: 512,
      backgroundColor: nil,
      foregroundColor: nil
    )

    #expect(isPNG(small))
    #expect(isPNG(large))
    #expect(small.count < large.count)
  }
}
