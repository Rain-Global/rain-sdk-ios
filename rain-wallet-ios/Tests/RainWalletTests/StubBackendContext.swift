import AuthenticationServices
import Combine
import Foundation
import TurnkeySwift
@testable import RainTurnkey

/// Minimal inert `TurnkeyContextProtocol` so RainWallet tests can construct providers without
/// touching the vendor singleton (which traps unconfigured in a test host). Test targets cannot
/// import each other, so this is deliberately not RainTurnkeyTests' richer `MockTurnkey`.
final class StubBackendContext: TurnkeyContextProtocol, @unchecked Sendable {
  var wallets: [Wallet] = []
  var turnkeyClient: (any TurnkeyClientProtocol)?
  var session: Session?
  var authState: AuthState = .unAuthenticated

  var authStatePublisher: AnyPublisher<AuthState, Never> {
    Just(authState).eraseToAnyPublisher()
  }

  var sessionPublisher: AnyPublisher<Session?, Never> {
    Just(session).eraseToAnyPublisher()
  }

  func refreshWallets() async throws {}
  func refreshTurnkeySession(expirationSeconds: String?) async throws {}

  func signRawPayload(
    signWith: String,
    payload: String,
    encoding: PayloadEncoding,
    hashFunction: HashFunction
  ) async throws -> SignRawPayloadResult {
    throw RainError.walletUnavailable()
  }

  var selectedStoredSessionKey: String?

  // The device half of the code flow — canned, the RainWallet tests only check delegation.
  func createOtpKeyPair() throws -> String { "stub-key" }
  func encryptOtpCode(_ code: String, otpEncryptionTargetBundle: String, publicKey: String) throws -> String { "enc" }
  func clientSignatureForLogin(verificationToken: String) throws -> (message: String, publicKey: String) {
    ("login", "stub-key")
  }
  func clientSignatureForSignup(
    verificationToken: String, email: String?, phoneNumber: String?
  ) throws -> (message: String, publicKey: String) {
    ("signup", "stub-key")
  }
  func signClientMessage(_ message: String, publicKey: String) async throws -> String { "sig" }
  var storeSessionCalls: [String] = []
  func storeTurnkeySession(jwt: String, sessionKey: String) async throws {
    storeSessionCalls.append(sessionKey)
  }

  func selectStoredSession(sessionKey: String) async throws {}

  func clearStoredSession(sessionKey: String?) {}

  func createTurnkeyWallet(
    walletName: String,
    accounts: [WalletAccountParams],
    mnemonicLength: Int
  ) async throws {}

  func addAccountsToTurnkeyWallet(
    walletId: String,
    accounts: [WalletAccountParams]
  ) async throws {}

  var loginWithPasskeyCallCount = 0
  var registerPasskeyCalls: [String] = []
  var addPasskeyCalls: [String] = []

  func loginWithTurnkeyPasskey(anchor: ASPresentationAnchor) async throws {
    loginWithPasskeyCallCount += 1
  }

  func makeTemporaryApiKey() -> TemporaryApiKey {
    TemporaryApiKey(publicKey: "02stub", privateKey: "stub")
  }

  func registerPasskey(anchor: ASPresentationAnchor, rpId: String) async throws -> PasskeyRegistration {
    registerPasskeyCalls.append(rpId)
    return PasskeyRegistration(
      challenge: "c", credentialId: "id", clientDataJson: "cd", attestationObject: "ao", transports: []
    )
  }

  func loginWithTemporaryKey(organizationId: String, key: TemporaryApiKey, sessionKey: String) async throws {}

  func addPasskeyAuthenticator(anchor: ASPresentationAnchor, rpId: String) async throws {
    addPasskeyCalls.append(rpId)
  }

  var setUserEmailCalls: [(String, String?)] = []
  var setUserPhoneNumberCalls: [(String, String?)] = []

  func setUserEmail(_ email: String, verificationToken: String?) async throws {
    setUserEmailCalls.append((email, verificationToken))
  }

  func setUserPhoneNumber(_ phone: String, verificationToken: String?) async throws {
    setUserPhoneNumberCalls.append((phone, verificationToken))
  }

  var exportMnemonicCalls: [String] = []
  var stubbedMnemonic = "stub mnemonic"

  struct ExportKeyCall: Equatable { let address: String; let encoding: ExportedKeyEncoding }
  var exportKeyCalls: [ExportKeyCall] = []
  var stubbedExportedKey = "stub-key"

  func exportWalletMnemonic(walletId: String) async throws -> String {
    exportMnemonicCalls.append(walletId)
    return stubbedMnemonic
  }

  func exportAccountPrivateKey(
    address: String,
    encoding: ExportedKeyEncoding
  ) async throws -> String {
    exportKeyCalls.append(ExportKeyCall(address: address, encoding: encoding))
    return stubbedExportedKey
  }
}

/// rain-api's device endpoints, canned: every contact already has a wallet, every code is right.
final class StubRainApiAuthClient: RainApiAuthClientProtocol, @unchecked Sendable {
  var tokens: [String] = []
  var verificationToken = "stub-vt"

  func initOtp(token: String) async throws -> RainApiOtpChallenge {
    tokens.append(token)
    return RainApiOtpChallenge(otpId: "otp", otpEncryptionTargetBundle: "bundle")
  }
  func verifyOtp(token: String, otpId: String, encryptedOtpBundle: String) async throws -> RainApiVerification {
    tokens.append(token)
    return RainApiVerification(verificationToken: verificationToken)
  }
  func signup(token: String, verificationToken: String, clientSignature: RainApiClientSignature) async throws -> RainApiSignup {
    tokens.append(token)
    return RainApiSignup(subOrganizationId: "sub")
  }
  func login(
    token: String, verificationToken: String, clientSignature: RainApiClientSignature, subOrganizationId: String?
  ) async throws -> RainApiLogin {
    tokens.append(token)
    return RainApiLogin(
      sessionToken: "jwt", expiresAt: "", providerUserId: "u", walletAddress: "0xeth-address", solanaAddress: "sol-address"
    )
  }
  func signupPasskey(token: String, attestation: RainApiPasskeyAttestation) async throws -> RainApiSignup {
    tokens.append(token)
    return RainApiSignup(subOrganizationId: "sub")
  }
}

final class StubPendingPasskeySignupStore: PendingPasskeySignupStore, @unchecked Sendable {
  var registration: PasskeyRegistration?
  func load() -> PasskeyRegistration? { registration }
  func save(_ registration: PasskeyRegistration) { self.registration = registration }
  func clear() { registration = nil }
}
