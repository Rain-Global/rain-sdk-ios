import Foundation
import RainCore

/// Fetches the wallet's transaction history on the active chain (latest 20, newest first).
@MainActor
final class TransactionHistoryViewModel: ObservableObject {
  @Published private(set) var transactions: [RainTransaction] = []
  @Published private(set) var walletAddress: String?
  @Published private(set) var isLoading = false
  @Published private(set) var errorText: String?

  private let session: RainSDKService

  init() {
    self.session = .shared
  }

  func fetchTransactions(chain: WalletChain) async {
    SampleLog.i("History.fetch", "fetching transactions chain=\(chain.displayName) limit=20 order=DESC")
    isLoading = true
    errorText = nil
    // Clear the previous chain's list so switching chains doesn't show stale rows.
    transactions = []

    do {
      let client = try session.requireClient()
      walletAddress = try? await client.getWalletAddress(chainId: chain.chainId)
      let result = try await client.getTransactions(
        chainId: chain.chainId,
        limit: 20,
        offset: nil,
        order: .DESC
      )
      SampleLog.i("History.fetch", "success — count=\(result.count)")
      transactions = result
    } catch {
      SampleLog.e("History.fetch", "failed: \(error.localizedDescription)")
      errorText = error.localizedDescription
    }
    isLoading = false
  }
}
