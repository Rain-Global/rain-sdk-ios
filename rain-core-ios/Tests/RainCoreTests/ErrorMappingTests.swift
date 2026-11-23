import Testing
import Foundation
@testable import RainCore

/// Turnkey + generic error-mapping cases. Portal error mapping is registered at runtime by
/// `PortalProvider` (so RainCore never imports PortalSwift); those cases live in `RainPortalTests`.
@Suite("RainError Mapping Tests")
struct ErrorMappingTests {


  @Test("from(_:) returns RainError unchanged when input is already a RainError")
  func testRainErrorPassthrough() {
    let original = RainError.invalidConfig(details: "x")
    let mapped = RainError.from(underlying: original)
    #expect(mapped == original)
  }

  @Test("from(_:) maps NSURLErrorDomain errors to networkError")
  func testNSURLErrorMapsToNetworkError() {
    let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
    let mapped = RainError.from(underlying: underlying)

    if case .networkError = mapped {
      // OK
    } else {
      Issue.record("Expected .networkError, got \(mapped)")
    }
  }

  @Test("from(_:) maps unknown NSError to providerError")
  func testUnknownErrorMapsToProviderError() {
    let underlying = NSError(domain: "SomeRandomDomain", code: 123, userInfo: nil)
    let mapped = RainError.from(underlying: underlying)

    if case .providerError = mapped {
      // OK
    } else {
      Issue.record("Expected .providerError, got \(mapped)")
    }
  }

  // Pins the published error-code map — a contract host apps switch on.
  // A failure here means the platforms have drifted — fix the code, not the test.
  @Test("error codes match the cross-platform map")
  func testErrorCodeParityMap() {
    let underlying = NSError(domain: "Test", code: 1, userInfo: nil)
    let expected: [(RainError, String)] = [
      (.sdkNotInitialized, "RAIN_101"),
      (.invalidConfig(details: "x"), "RAIN_102"),
      (.providerNotRegistered(details: "x"), "RAIN_102"),
      (.invalidRpcUrl("x"), "RAIN_103"),
      (.chainNotSupported(chainId: 43114, details: "x"), "RAIN_104"),
      (.tokenExpired, "RAIN_201"),
      (.unauthorized(), "RAIN_202"),
      (.invalidLoginCode, "RAIN_203"),
      (.networkError(underlying: underlying), "RAIN_301"),
      (.transactionPending(statusId: "status-1"), "RAIN_302"),
      // 303/304 are retired; the 3xx sequence resumes at 305 on both platforms.
      (.transactionOutcomeUnknown(details: "x"), "RAIN_305"),
      (.userRejected, "RAIN_401"),
      (.insufficientFunds(required: "1", available: "0"), "RAIN_402"),
      (.transactionSimulationFailed(underlying: underlying), "RAIN_403"),
      (.walletUnavailable(), "RAIN_404"),
      (.withdrawalRevertedByNetwork(), "RAIN_405"),
      (.invalidAmount(amount: "1.005", reason: "too many decimals"), "RAIN_406"),
      (.walletNotAuthorized(walletAddress: "0x1", proxyAddress: "0x2"), "RAIN_407"),
      // Token-transfer failures reuse existing codes on purpose — the code map is shared with the
      // published contract, so a new code would fork it.
      (.insufficientTokenBalance(requested: "2", available: "1", token: "mint"), "RAIN_402"),
      (.tokenAccountNotFound(walletAddress: "wallet", token: "mint"), "RAIN_402"),
      (.tokenNotFound(token: "mint", chainId: 103), "RAIN_102"),
      (.invalidRecipient(address: "addr", reason: "because"), "RAIN_102"),
      (.providerError(underlying: underlying), "RAIN_501"),
      (.internalError(details: "x"), "RAIN_502"),
    ]
    for (error, code) in expected {
      #expect(error.code == code)
      requireMappedCase(error)
    }
  }

  /// Fails to compile when a `RainError` case is added but not listed here.
  private func requireMappedCase(_ error: RainError) {
    switch error {
    case .sdkNotInitialized,
         .invalidConfig,
         .providerNotRegistered,
         .invalidRpcUrl,
         .chainNotSupported,
         .tokenExpired,
         .unauthorized,
         .invalidLoginCode,
         .networkError,
         .transactionPending,
         .transactionOutcomeUnknown,
         .userRejected,
         .insufficientFunds,
         .transactionSimulationFailed,
         .walletUnavailable,
         .withdrawalRevertedByNetwork,
         .invalidAmount,
         .walletNotAuthorized,
         .insufficientTokenBalance,
         .tokenAccountNotFound,
         .tokenNotFound,
         .invalidRecipient,
         .providerError,
         .internalError:
      break
    }
  }

  // MARK: - Equality

  @Test("== distinguishes different cases that share an error code")
  func testEqualityDistinguishesCasesSharingACode() {
    // RAIN_402 trio
    #expect(
      RainError.insufficientFunds(required: "1", available: "0")
        != RainError.tokenAccountNotFound(walletAddress: "w", token: "t")
    )
    #expect(
      RainError.insufficientFunds(required: "1", available: "0")
        != RainError.insufficientTokenBalance(requested: "2", available: "1", token: "t")
    )
    // RAIN_102 family
    #expect(RainError.invalidConfig(details: "x") != RainError.tokenNotFound(token: "t", chainId: 1))
    #expect(RainError.invalidConfig(details: "x") != RainError.providerNotRegistered(details: "x"))
    #expect(
      RainError.tokenNotFound(token: "t", chainId: 1)
        != RainError.invalidRecipient(address: "a", reason: "r")
    )
  }

  @Test("== treats same-case values as equal regardless of payload")
  func testEqualityIsPayloadInsensitive() {
    #expect(RainError.invalidConfig(details: "a") == RainError.invalidConfig(details: "b"))
    #expect(
      RainError.insufficientFunds(required: "1", available: "0")
        == RainError.insufficientFunds(required: "9", available: "8")
    )
    #expect(RainError.unauthorized() == RainError.unauthorized())
    #expect(RainError.tokenExpired == RainError.tokenExpired)
  }

  // MARK: - Untyped vendor prose
  //
  // Standard: a message classifies only on a phrase of at least two words (or EIP-1193 code
  // 4001). A lone "rejected" / "cancelled" / "insufficient" is not enough.

  @Test("from(_:) maps a user-rejection phrase to userRejected")
  func testRejectionPhrasesMapToUserRejected() {
    for message in [
      "User rejected the request",
      "User denied transaction signature",
      "User cancelled signing",
      "User canceled signing",
      "User declined the request",
      "Signature rejected by user",
      "Request denied by user",
      "Transaction cancelled by user",
      "Request denied by the user",
    ] {
      let mapped = RainError.from(underlying: VendorProseError(message))
      #expect(mapped == RainError.userRejected, "expected userRejected for: \(message)")
    }
  }

  @Test("from(_:) maps EIP-1193 code 4001 to userRejected")
  func testCode4001MapsToUserRejected() {
    for message in ["code: 4001, message: nope", "RPC error [4001]", "Provider error (4001)"] {
      let mapped = RainError.from(underlying: VendorProseError(message))
      #expect(mapped == RainError.userRejected, "expected userRejected for: \(message)")
    }
    let coded = NSError(domain: "vendor", code: 4001, userInfo: nil)
    #expect(RainError.from(underlying: coded) == RainError.userRejected)
  }

  @Test("from(_:) maps an insufficient-funds phrase to insufficientFunds")
  func testInsufficientPhrasesMapToInsufficientFunds() {
    for message in [
      "insufficient funds for gas * price + value",
      "Insufficient balance for transfer",
      "Transfer: insufficient lamports 100, need 5000",
      "Attempt to debit an account but found no record of a prior credit.",
    ] {
      let mapped = RainError.from(underlying: VendorProseError(message))
      #expect(mapped.code == "RAIN_402", "expected RAIN_402 for: \(message)")
    }
  }

  @Test("from(_:) leaves an unrecognized message as providerError")
  func testUnrecognizedProseStaysProviderError() {
    let mapped = RainError.from(underlying: VendorProseError("nonce too low"))
    if case .providerError = mapped {} else {
      Issue.record("expected providerError, got \(mapped)")
    }
  }

  @Test("from(_:) does not classify on a single word")
  func testSingleWordDoesNotClassify() {
    for message in [
      "User doesn't have an embedded wallet",
      "Transaction cancelled",
      "request was denied",
      "Rejected: nonce too low",
      "insufficient permissions for this operation",
      "nonce 4001 too low",
    ] {
      let mapped = RainError.from(underlying: VendorProseError(message))
      if case .providerError = mapped {} else {
        Issue.record("expected providerError for: \(message), got \(mapped)")
      }
    }
  }

  // Plain Swift errors (no LocalizedError) render a generic localizedDescription, so
  // classification must also read the debug description, splitting camelCase case names.

  @Test("from(_:) classifies a plain Swift error whose case text says insufficient funds")
  func testPlainErrorInsufficientFunds() {
    let mapped = RainError.from(underlying: PlainVendorError.insufficientFundsForTransfer)
    #expect(mapped == RainError.insufficientFunds(required: "unknown", available: "unknown"))

    let prose = RainError.from(underlying: PlainVendorError.prose("insufficient funds for gas"))
    #expect(prose == RainError.insufficientFunds(required: "unknown", available: "unknown"))
  }

  @Test("from(_:) classifies a plain Swift error whose case text says the user rejected")
  func testPlainErrorUserRejection() {
    #expect(RainError.from(underlying: PlainVendorError.userRejectedSignature) == RainError.userRejected)
    #expect(RainError.from(underlying: PlainVendorError.prose("denied by user")) == RainError.userRejected)
  }

  @Test("from(_:) does not classify Task cancellation as a user rejection")
  func testCancellationErrorIsNotUserRejected() {
    let mapped = RainError.from(underlying: CancellationError())
    if case .providerError = mapped {} else {
      Issue.record("expected providerError, got \(mapped)")
    }
  }
}

/// A vendor error that carries its meaning only in prose — the shape the keyword fallback exists
/// for, and the shape Portal and Turnkey both produce for rejections and funds shortfalls.
private struct VendorProseError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { self.errorDescription = message }
}

/// A plain Swift error (not LocalizedError): its meaning lives only in the case name or
/// associated text, and its localizedDescription is the generic NSError placeholder.
private enum PlainVendorError: Error {
  case insufficientFundsForTransfer
  case userRejectedSignature
  case prose(String)
}
