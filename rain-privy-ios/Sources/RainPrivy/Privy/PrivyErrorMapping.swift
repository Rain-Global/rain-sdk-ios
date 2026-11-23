import Foundation
import PrivySDK
import RainCore

/// Registers Privy vendor-error mapping with `RainCore`'s extensible error mapper, so Privy errors
/// classify into `RainError` cases (`.userRejected`, `.insufficientFunds`, `.tokenExpired`, …)
/// without RainCore importing PrivySDK.
enum PrivyErrorMapping {
  nonisolated(unsafe) private static var registered = false
  private static let lock = NSLock()

  /// Registers the mapper exactly once per process.
  static func registerOnce() {
    lock.lock(); defer { lock.unlock() }
    guard !registered else { return }
    registered = true
    RainError.registerErrorMapper(map)
  }

  /// Returns a classified `RainError` for a Privy vendor error, or `nil` for anything this
  /// adapter doesn't own (so core's built-in fallbacks still run). Internal (not private) so
  /// the session coordinator can classify auth failures without re-stating vendor shapes.
  static func map(_ error: Error) -> RainError? {
    guard let privyError = error as? PrivyError else { return nil }
    switch privyError.errorCode {
    case .authenticationFailure(let reason):
      return mapAuthenticationFailure(reason, error: privyError)
    case .embeddedWalletFailure(let reason):
      return mapEmbeddedWalletFailure(reason, error: privyError)
    case .initializationFailed:
      return .providerError(underlying: privyError)
    @unknown default:
      return .providerError(underlying: privyError)
    }
  }

  private static func mapAuthenticationFailure(
    _ reason: PrivyErrorCode.AuthenticationFailureReason,
    error: PrivyError
  ) -> RainError {
    switch reason {
    case .notLoggedIn, .invalidJwt, .sessionExpired:
      return .tokenExpired
    case .passkeyUserCancelled:
      return .userRejected
    case .failureDuringAuthentication(let underlying):
      // May wrap ASAuthorizationError.canceled / a network error; recurse so it classifies.
      return RainError.from(underlying: underlying)
    default:
      return .providerError(underlying: error)
    }
  }

  private static func mapEmbeddedWalletFailure(
    _ reason: PrivyErrorCode.EmbeddedWalletFailureReason,
    error: PrivyError
  ) -> RainError {
    switch reason {
    case .noWalletAvailable, .creationFailed:
      return .walletUnavailable(details: "Privy has no embedded wallet available (\(reason))")
    case .unsupportedChain, .rpcUrlNotFound:
      // A misconfiguration rather than a provider failure at runtime.
      return .internalError(details: "Privy: \(error.localizedDescription)")
    // The EIP-1193 and Solana send paths surface node / user-facing failures as these
    // message-carrying cases; classify by message.
    case .jsonRpcError(let message),
         .signerError(let message),
         .transactionError(let message),
         .invalidSolanaTransaction(let message):
      return classify(message: message, fallback: error)
    case .invalidRpcParams(_, let description):
      return classify(message: description, fallback: error)
    case .iframeError(_, let message):
      return classify(message: message, fallback: error)
    default:
      return .providerError(underlying: error)
    }
  }

  /// Classifies Privy's free-text RPC error messages by core's shared vendor-phrase standard.
  private static func classify(message: String, fallback: PrivyError) -> RainError {
    RainError.fromVendorMessage(message) ?? .providerError(underlying: fallback)
  }
}
