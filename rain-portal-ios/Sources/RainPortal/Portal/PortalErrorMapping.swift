import Foundation
import PortalSwift
@_spi(RainAdapter) import RainCore

/// Registers Portal vendor-error mapping with `RainCore`'s extensible error mapper, so Portal
/// errors classify into `RainError` cases without RainCore importing PortalSwift.
enum PortalErrorMapping {
  nonisolated(unsafe) private static var registered = false
  private static let lock = NSLock()

  /// Registers the mapper exactly once per process.
  static func registerOnce() {
    lock.lock(); defer { lock.unlock() }
    guard !registered else { return }
    registered = true
    RainError.registerErrorMapper(map)
  }

  private static func map(_ error: Error) -> RainError? {
    if let authError = mapAuthOrNil(error) {
      return authError
    }
    if let rpcError = error as? PortalRpcError {
      return mapPortalRpcError(rpcError)
    }
    return nil
  }

  /// Auth-only mapping (401 / invalid API key → `.tokenExpired`). Call sites that deliberately
  /// wrap Portal errors themselves — and so never reach the registered mapper — use this so an
  /// expired session still classifies correctly. Returns `nil` for everything else.
  static func mapAuthOrNil(_ error: Error) -> RainError? {
    if let requestError = error as? PortalRequestsError {
      return mapPortalRequestsError(requestError)
    }
    if let mpcError = error as? PortalMpcError {
      return mapPortalMpcError(mpcError)
    }
    return nil
  }

  private static func mapPortalRequestsError(_ error: PortalRequestsError) -> RainError? {
    switch error {
    case .unauthorized:
      // Portal routes HTTP 401 to .unauthorized upstream, so this is the only path token-expired
      // errors reach the SDK through.
      return .tokenExpired
    default:
      // Unrecognized: let the call site keep its own wrapping.
      return nil
    }
  }

  private static func mapPortalMpcError(_ error: PortalMpcError) -> RainError? {
    let code = error.id.flatMap { Int($0) }
    if code == 320 || code == PortalErrorCodes.INVALID_API_KEY.rawValue {
      return .tokenExpired
    }
    return nil
  }

  /// HTTP 5xx, or 408/429 (which Portal only surfaces as the `"<status> - …"` prefix of `.clientError`).
  static func isTransient(_ error: Error) -> Bool {
    guard let requestError = error as? PortalRequestsError else { return false }
    switch requestError {
    case .internalServerError:
      return true
    case .clientError(let message, _):
      let status = Int(message.components(separatedBy: " - ").first ?? "")
      return status == 408 || status == 429
    case .couldNotParseHttpResponse, .redirectError, .unauthorized:
      return false
    }
  }

  private static func mapPortalRpcError(_ error: PortalRpcError) -> RainError {
    // Core's shared revert rule. Portal answers "execution reverted" with code `3`, which
    // PortalSwift does not declare. Only send and fee-estimation flows can surface a revert
    // here: contract-balance reads wrap Portal errors into
    // `.providerError` inside the adapter before core's mapper runs, and the remaining reads
    // (eth_getBalance, assets, transaction history) never execute EVM code. Withdrawal flows
    // translate this into `.withdrawalRevertedByNetwork` (RAIN_405) in core.
    let message = String(describing: error) + " " + error.localizedDescription
    if JsonRpcClient.isRevert(code: error.code, message: message, data: nil) {
      return .transactionSimulationFailed(underlying: error)
    }
    return .providerError(underlying: error)
  }
}
