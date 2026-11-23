import Foundation
import UIKit
import RainCore

/// Loads the wallet address and the collateral deposit address for the active chain, each with a
/// QR code.
@MainActor
final class WalletInfoViewModel: ObservableObject {
  @Published private(set) var walletAddress = ""
  @Published private(set) var walletQR: UIImage?
  @Published private(set) var collateralAddress = ""
  @Published private(set) var collateralQR: UIImage?
  @Published private(set) var isLoading = false
  @Published private(set) var errorText: String?

  private let session: RainSDKService

  init() {
    self.session = .shared
  }

  func fetchWalletInfo(chain: WalletChain) async {
    SampleLog.i("WalletInfo", "fetching wallet info chain=\(chain.displayName)")
    isLoading = true
    errorText = nil
    // Clear stale data when switching chains so the previous wallet doesn't linger.
    walletAddress = ""
    walletQR = nil
    collateralAddress = ""
    collateralQR = nil

    do {
      let client = try session.requireClient()
      let address = try await client.getWalletAddress(chainId: chain.chainId)
      SampleLog.d("WalletInfo", "wallet address=\(address)")
      walletAddress = address
      walletQR = try await qrImage(client: client, address: address)

      // The collateral contract comes from the Rain API — the host's call, not the SDK's.
      guard let contract = try await session.fetchCollateralContract(for: chain) else {
        SampleLog.w("WalletInfo", "no collateral contract for \(chain.displayName)")
        errorText = "No collateral contract on \(chain.displayName)"
        isLoading = false
        return
      }
      // Deposits go to the dedicated deposit address when Rain provides one (distinct from the
      // collateral account on Solana); EVM contracts deposit at the proxy.
      let depositTarget = contract.depositAddress ?? contract.proxyAddress
      SampleLog.d("WalletInfo", "collateral address=\(depositTarget) (chainId=\(contract.chainId))")
      collateralAddress = depositTarget
      collateralQR = try await qrImage(client: client, address: depositTarget)
      SampleLog.i("WalletInfo", "success")
    } catch {
      SampleLog.e("WalletInfo", "failed: \(error.localizedDescription)")
      errorText = error.localizedDescription
    }
    isLoading = false
  }

  /// QR codes come from the SDK, which renders any address (the wallet's own chain-aware address
  /// or the collateral deposit address).
  private func qrImage(client: RainClient, address: String) async throws -> UIImage? {
    UIImage(data: try await client.generateAddressQRCode(address: address))
  }
}
