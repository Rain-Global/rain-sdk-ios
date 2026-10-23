import Foundation
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// rain-api's device endpoints, scripted. Records every call with the token it rode on, and
/// models the backend's account state: `walletsByContact` is what `/login` consults (404 when
/// absent) and `/signup` writes (idempotently).
final class MockRainApiAuthClient: RainApiAuthClientProtocol, @unchecked Sendable {
  struct Call: Equatable {
    enum Endpoint: Equatable { case initOtp, verifyOtp, signup, login, signupPasskey }
    let endpoint: Endpoint
    let token: String
  }

  var calls: [Call] = []
  var endpoints: [Call.Endpoint] { calls.map(\.endpoint) }

  var challenge = RainApiOtpChallenge(otpId: "otp-1", otpEncryptionTargetBundle: "bundle-1")
  var verificationToken = "vt-1"
  var login = RainApiLogin(
    sessionToken: "jwt-1", expiresAt: "2026-10-21T00:15:00Z", providerUserId: "user-1",
    walletAddress: "0xeddf67f4b6ba6da613cc1c24433073d6ab4c885d",
    solanaAddress: "7YP827Y77YQTU7MS8R9JGMVJKAkvyiBg6sEVJNeRibge"
  )
  /// Contacts (normalized) that already have a wallet → their sub-organization id. `/login`
  /// answers 404 for anyone else; `/signup` adds them.
  var walletsByContact: [String: String] = [:]
  /// The contact `/signup` and `/login` are "bound to" (what the token encodes). Set by tests
  /// to the normalized contact under test so signup lands in `walletsByContact`.
  var tokenContact = "user@example.com"
  var nextSubOrganizationId = "sub-1"

  var initOtpError: Error?
  var verifyOtpError: Error?
  var signupError: Error?
  var loginError: Error?
  var signupPasskeyError: Error?
  /// Errors thrown by successive `signupPasskey` calls, consumed in order; `signupPasskeyError`
  /// applies once the queue is empty.
  var signupPasskeyErrors: [Error] = []
  /// Tokens rain-api treats as expired/revoked (401) on any call.
  var rejectedTokens: Set<String> = []

  var verifyOtpBodies: [(otpId: String, encryptedOtpBundle: String)] = []
  var loginBodies: [(verificationToken: String, clientSignature: RainApiClientSignature, subOrganizationId: String?)] = []
  var signupBodies: [(verificationToken: String, clientSignature: RainApiClientSignature)] = []
  var passkeyBodies: [RainApiPasskeyAttestation] = []

  private func record(_ endpoint: Call.Endpoint, _ token: String) throws {
    calls.append(Call(endpoint: endpoint, token: token))
    if rejectedTokens.contains(token) {
      throw RainApiAuthError(kind: .tokenRejected, statusCode: 401, message: "Token expired")
    }
  }

  func initOtp(token: String) async throws -> RainApiOtpChallenge {
    try record(.initOtp, token)
    if let initOtpError { throw initOtpError }
    return challenge
  }

  func verifyOtp(token: String, otpId: String, encryptedOtpBundle: String) async throws -> RainApiVerification {
    try record(.verifyOtp, token)
    verifyOtpBodies.append((otpId, encryptedOtpBundle))
    if let verifyOtpError { throw verifyOtpError }
    return RainApiVerification(verificationToken: verificationToken)
  }

  func signup(token: String, verificationToken: String, clientSignature: RainApiClientSignature) async throws -> RainApiSignup {
    try record(.signup, token)
    signupBodies.append((verificationToken, clientSignature))
    if let signupError { throw signupError }
    // Idempotent: an existing wallet is returned, not duplicated.
    if let existing = walletsByContact[tokenContact] { return RainApiSignup(subOrganizationId: existing) }
    walletsByContact[tokenContact] = nextSubOrganizationId
    return RainApiSignup(subOrganizationId: nextSubOrganizationId)
  }

  func login(
    token: String, verificationToken: String, clientSignature: RainApiClientSignature, subOrganizationId: String?
  ) async throws -> RainApiLogin {
    try record(.login, token)
    loginBodies.append((verificationToken, clientSignature, subOrganizationId))
    if let loginError { throw loginError }
    guard walletsByContact[tokenContact] != nil else {
      throw RainApiAuthError(kind: .noWallet, statusCode: 404, message: "No wallet exists for this contact")
    }
    return login
  }

  func signupPasskey(token: String, attestation: RainApiPasskeyAttestation) async throws -> RainApiSignup {
    try record(.signupPasskey, token)
    passkeyBodies.append(attestation)
    if !signupPasskeyErrors.isEmpty { throw signupPasskeyErrors.removeFirst() }
    if let signupPasskeyError { throw signupPasskeyError }
    return RainApiSignup(subOrganizationId: nextSubOrganizationId)
  }
}

/// In-memory stand-in for the persisted pending-signup store.
final class InMemoryPendingPasskeySignupStore: PendingPasskeySignupStore, @unchecked Sendable {
  var registration: PasskeyRegistration?
  var saveCount = 0
  var clearCount = 0
  func load() -> PasskeyRegistration? { registration }
  func save(_ registration: PasskeyRegistration) { self.registration = registration; saveCount += 1 }
  func clear() { registration = nil; clearCount += 1 }
}
