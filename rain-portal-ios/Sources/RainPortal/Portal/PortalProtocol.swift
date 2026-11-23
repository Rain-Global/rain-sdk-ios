import Foundation
import PortalSwift
import RainCore

/// Protocol that abstracts Portal's interface for testing
/// This allows us to mock Portal in tests while keeping the public API unchanged
/// Note: Renamed from PortalProtocol to avoid conflict with PortalSwift's PortalProtocol
internal protocol PortalRequestProtocol {
  var addresses: [PortalNamespace: String?] { get async throws }
  
  func request(
    chainId: String,
    method: PortalRequestMethod,
    params: [Any],
    options: RequestOptions?
  ) async throws -> PortalProviderResult
  
  /// Fetches ERC-20 (and optionally other) token balances for the current wallet on the given chain (e.g. "eip155:1").
  func getAssets(
    _ chainId: String
  ) async throws -> AssetsResponse
  
  func getTransactions(
    _ chainId: String,
    limit: Int?,
    offset: Int?,
    order: TransactionOrder?
  ) async throws -> [FetchedTransaction]
}

/// Extension to make Portal conform to PortalRequestProtocol
/// Since Portal is from PortalSwift, we extend it to conform to our protocol
extension Portal: PortalRequestProtocol {
  // Portal already implements these methods, so no additional code needed
  // This extension allows Portal to be used wherever PortalRequestProtocol is required
}
