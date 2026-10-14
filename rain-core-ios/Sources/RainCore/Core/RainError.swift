import Foundation

/// Errors that can occur in the Rain SDK
/// Structured with error codes for easy identification and debugging
public enum RainError: Error, LocalizedError, Equatable {
  // MARK: - 1xx: Initialization Errors
  
  /// RAIN_101: Business methods were called before initialize() was successfully completed
  case sdkNotInitialized
  
  /// RAIN_102: Invalid SDK configuration or parameter — `details` says what was wrong.
  case invalidConfig(details: String)

  /// RAIN_102: No provider registered for the requested id / capability.
  case providerNotRegistered(details: String)

  /// RAIN_103: An RPC URL could not be parsed as a valid URL (no chain ID context)
  case invalidRpcUrl(String)

  /// RAIN_104: The active wallet provider cannot broadcast on this chain, so a send (transfer,
  /// withdrawal, approval) was refused before any signing or network work. Reads — balances,
  /// history, fee estimates — are not gated. E.g. Turnkey's managed broadcast does not cover
  /// Avalanche.
  case chainNotSupported(chainId: Int, details: String)

  // MARK: - 2xx: Authentication Errors

  /// RAIN_201: The wallet provider session token has expired or is no longer valid
  case tokenExpired

  /// RAIN_202: The backend rejected the caller's credentials or permissions for this operation.
  /// `details` says which backend and why (e.g. a Turnkey 403, an empty Portal session token).
  case unauthorized(details: String = "Invalid credentials or insufficient permissions")

  /// RAIN_203: The one-time login code was rejected (wrong, expired, or already used) — ask the
  /// user to retype it or request a new one. Distinct from `tokenExpired`, which means an
  /// established session died.
  case invalidLoginCode

  // MARK: - 3xx: Network Errors

  /// RAIN_301: Connectivity issues preventing communication with APIs or Blockchain nodes
  case networkError(underlying: Error)

  /// RAIN_302: The transaction was accepted by the wallet provider but its hash was not yet
  /// visible when status polling stopped. NOT a failure — the transaction may still confirm, and
  /// resending it risks a duplicate transfer. Resume polling with `statusId` instead. On a
  /// Turnkey / Rain wallet send whose activity the backend accepted without a readable status
  /// id yet, `statusId` is the backend's ACTIVITY id — no SDK call takes it, but it matches the
  /// history row for the send. Same code and meaning on Android.
  case transactionPending(statusId: String)

  /// RAIN_305: The send was handed to the wallet provider and the SDK then lost track of it — a
  /// server error, a transport failure or an unreadable answer AFTER the provider may already have
  /// accepted it — so there is no identifier to resume from. NOT a settled failure: the
  /// transaction may still land, and resending risks a duplicate transfer. Read history or the
  /// balance before sending again. Carries no cause on purpose, so no layer can read an HTTP
  /// status off it and retry. (RAIN_303/304 were retired; the 3xx sequence resumes here, as on
  /// Android.)
  case transactionOutcomeUnknown(details: String)


  // MARK: - 4xx: User Action Errors
  
  /// RAIN_401: The user manually cancelled the signature request within the wallet UI
  case userRejected
  
  /// RAIN_402: The wallet balance is too low for the withdrawal amount or the required gas fees
  case insufficientFunds(required: String, available: String)
  
  /// RAIN_403: Transaction simulation (preflight) failed before submission, e.g. a contract revert surfaced by `eth_call`
  case transactionSimulationFailed(underlying: Error)

  /// RAIN_404: No wallet address available from the wallet provider (e.g. the user has not
  /// connected or created a wallet, or the provider holds no account for this chain family).
  case walletUnavailable(details: String = "No wallet address from the wallet provider")

  /// RAIN_405: The collateral contract rejected the withdrawal (reverted on chain or in the
  /// preflight) — typically an already-used or expired admin signature, or a duplicate amount
  /// inside the cooldown window. `details` carries the decoded reason when one is available.
  case withdrawalRevertedByNetwork(details: String = "Withdrawal reverted by the network")

  /// RAIN_406: The amount is invalid for the token — more decimal places than the token supports, or negative/unrepresentable
  case invalidAmount(amount: String, reason: String)

  /// RAIN_407: The signing wallet is not an admin of the collateral contract, so `withdrawAsset`
  /// would reject its signature on-chain with `InvalidSignature()`
  case walletNotAuthorized(walletAddress: String, proxyAddress: String)

  // The four cases below are token-transfer failures callers need to tell apart in the UI. They
  // carry their own payloads but deliberately reuse existing error codes: the code map is a
  // published contract host apps switch on, so a new code would fork it.

  /// RAIN_402: The wallet holds less of the token than the transfer asks for — the shortfall is
  /// in the token itself, not in the chain's native currency.
  case insufficientTokenBalance(requested: String, available: String, token: String)

  /// RAIN_402: The wallet has no account for this token, so there is nothing to send. On Solana a
  /// balance lives in a per-mint token account that exists only once the wallet has received it.
  case tokenAccountNotFound(walletAddress: String, token: String)

  /// RAIN_102: No token exists at this address on this chain (wrong address, or wrong cluster).
  case tokenNotFound(token: String, chainId: Int)

  /// RAIN_102: The recipient address cannot receive this transfer — see `reason`.
  case invalidRecipient(address: String, reason: String)

  // MARK: - 5xx: Internal / Provider Errors
  
  /// RAIN_501: An unhandled error occurred within the wallet provider
  case providerError(underlying: Error)
  
  /// RAIN_502: Error processing EIP-712 data or internal state management failure
  case internalError(details: String)
  
  // MARK: - Error Code
  
  /// The error code (e.g., "RAIN_101")
  public var code: String {
    switch self {
    case .sdkNotInitialized:
      return "RAIN_101"
    case .invalidConfig, .providerNotRegistered, .tokenNotFound, .invalidRecipient:
      return "RAIN_102"
    case .invalidRpcUrl:
      return "RAIN_103"
    case .chainNotSupported:
      return "RAIN_104"
    case .tokenExpired:
      return "RAIN_201"
    case .unauthorized:
      return "RAIN_202"
    case .invalidLoginCode:
      return "RAIN_203"
    case .networkError:
      return "RAIN_301"
    case .transactionPending:
      return "RAIN_302"
    case .transactionOutcomeUnknown:
      return "RAIN_305"
    case .userRejected:
      return "RAIN_401"
    case .insufficientFunds, .insufficientTokenBalance, .tokenAccountNotFound:
      return "RAIN_402"
    case .transactionSimulationFailed:
      return "RAIN_403"
    case .walletUnavailable:
      return "RAIN_404"
    case .withdrawalRevertedByNetwork:
      return "RAIN_405"
    case .invalidAmount:
      return "RAIN_406"
    case .walletNotAuthorized:
      return "RAIN_407"
    case .providerError:
      return "RAIN_501"
    case .internalError:
      return "RAIN_502"
    }
  }
  
  // MARK: - LocalizedError
  
  public var errorDescription: String? {
    switch self {
    case .sdkNotInitialized:
      return "[\(code)] Business methods were called before initialize() was successfully completed."
    case .invalidConfig(let details):
      return "[\(code)] \(details)"
    case .providerNotRegistered(let details):
      return "[\(code)] \(details)"
    case .invalidRpcUrl(let rpcUrl):
      return "[\(code)] The provided RPC URL could not be parsed. RPC URL: \(rpcUrl)."
    case .chainNotSupported(let chainId, let details):
      return "[\(code)] Sends not supported on chain \(chainId): \(details)"
    case .tokenExpired:
      return "[\(code)] The wallet provider session token has expired or is no longer valid."
    case .unauthorized(let details):
      return "[\(code)] \(details)."
    case .invalidLoginCode:
      return "[\(code)] The one-time login code was rejected — wrong, expired, or already used. Retype it or request a new one."
    case .networkError(let underlying):
      return "[\(code)] Connectivity issues preventing communication with APIs or Blockchain nodes. \(underlying.localizedDescription)"
    case .transactionPending(let statusId):
      return "[\(code)] Transaction submitted but not yet confirmed (statusId=\(statusId)). Not a failure — resume polling with the status id; do not resend."
    case .transactionOutcomeUnknown(let details):
      return "[\(code)] \(details). The send may still land — check history or the balance before sending again; do not resend blindly."
    case .userRejected:
      return "[\(code)] The user manually cancelled the signature request within the wallet UI."
    case .insufficientFunds(let required, let available):
      return "[\(code)] The wallet balance is too low for the withdrawal amount or the required gas fees. Required: \(required). Available: \(available)."
    case .transactionSimulationFailed(let underlying):
      return "[\(code)] Transaction simulation failed before submission. \(underlying.localizedDescription)"
    case .walletUnavailable(let details):
      return "[\(code)] \(details)."
    case .withdrawalRevertedByNetwork(let details):
      return "[\(code)] \(details). Please try again in a few minutes."
    case .invalidAmount(let amount, let reason):
      return "[\(code)] Invalid amount (\(amount)): \(reason)."
    case .walletNotAuthorized(let walletAddress, let proxyAddress):
      return "[\(code)] Wallet \(walletAddress) is not an admin of collateral contract \(proxyAddress)."
    case .insufficientTokenBalance(let requested, let available, let token):
      return "[\(code)] Insufficient balance for \(token): requested \(requested), available \(available)."
    case .tokenAccountNotFound(let walletAddress, let token):
      return "[\(code)] Wallet \(walletAddress) holds no account for token \(token)."
    case .tokenNotFound(let token, let chainId):
      return "[\(code)] No token found at \(token) on chainId=\(chainId)."
    case .invalidRecipient(let address, let reason):
      return "[\(code)] Invalid recipient \(address): \(reason)."
    case .providerError(let underlying):
      return "[\(code)] An unhandled error occurred within the wallet provider. \(underlying.localizedDescription)"
    case .internalError(let details):
      return "[\(code)] Error processing EIP-712 data or internal state management failure. Details: \(details)"
    }
  }
}
extension RainError {
  /// Stable per-case name, payload-insensitive. Several cases share an code, so equality
  /// needs this to keep e.g. .insufficientFunds and .tokenAccountNotFound distinct.
  internal var caseIdentifier: String {
    switch self {
    case .sdkNotInitialized: return "sdkNotInitialized"
    case .invalidConfig: return "invalidConfig"
    case .providerNotRegistered: return "providerNotRegistered"
    case .invalidRpcUrl: return "invalidRpcUrl"
    case .chainNotSupported: return "chainNotSupported"
    case .tokenExpired: return "tokenExpired"
    case .unauthorized: return "unauthorized"
    case .invalidLoginCode: return "invalidLoginCode"
    case .networkError: return "networkError"
    case .transactionPending: return "transactionPending"
    case .transactionOutcomeUnknown: return "transactionOutcomeUnknown"
    case .userRejected: return "userRejected"
    case .insufficientFunds: return "insufficientFunds"
    case .transactionSimulationFailed: return "transactionSimulationFailed"
    case .walletUnavailable: return "walletUnavailable"
    case .withdrawalRevertedByNetwork: return "withdrawalRevertedByNetwork"
    case .invalidAmount: return "invalidAmount"
    case .walletNotAuthorized: return "walletNotAuthorized"
    case .insufficientTokenBalance: return "insufficientTokenBalance"
    case .tokenAccountNotFound: return "tokenAccountNotFound"
    case .tokenNotFound: return "tokenNotFound"
    case .invalidRecipient: return "invalidRecipient"
    case .providerError: return "providerError"
    case .internalError: return "internalError"
    }
  }

  /// Same enum case (payload-insensitive) and same published error code.
  public static func == (lhs: RainError, rhs: RainError) -> Bool {
    lhs.code == rhs.code && lhs.caseIdentifier == rhs.caseIdentifier
  }
}
