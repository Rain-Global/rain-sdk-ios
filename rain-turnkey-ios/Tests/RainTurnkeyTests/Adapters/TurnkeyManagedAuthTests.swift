import Testing
import AuthenticationServices
import Foundation
import TurnkeyHttp
import TurnkeySwift
@_spi(RainAdapter) @testable import RainCore
@_spi(RainWallet) @testable import RainTurnkey

@Suite("Turnkey Managed Auth")
struct TurnkeyManagedAuthTests {
  init() { TurnkeyErrorMapping.registerOnce() }

  /// A controller over the mock context and a scripted rain-api. The token provider mints
  /// "wat-1", "wat-2", … and records which contact each was asked for.
  private final class Harness: @unchecked Sendable {
    let turnkey: MockTurnkey
    let api = MockRainApiAuthClient()
    let pendingSignups = InMemoryPendingPasskeySignupStore()
    var tokenRequests: [TurnkeyLoginContact?] = []
    var tokenProviderError: Error?
    private(set) var controller: TurnkeyManagedAuthController!

    init(
      turnkey: MockTurnkey,
      configurationError: RainError? = nil,
      rpId: String? = nil,
      tokenProvider: Bool = true
    ) {
      self.turnkey = turnkey
      controller = TurnkeyManagedAuthController(
        context: turnkey,
        configurationError: configurationError,
        rpId: rpId,
        api: api,
        // Strong on purpose: `makeController` hands out the controller alone, and the closure
        // must outlive the harness that recorded into it. A test-scoped cycle is fine.
        tokenProvider: tokenProvider ? { @Sendable [self] contact in
          tokenRequests.append(contact)
          if let tokenProviderError { throw tokenProviderError }
          return "wat-\(tokenRequests.count)"
        } : nil,
        pendingPasskeySignups: pendingSignups
      )
    }

    var tokens: [String] { api.calls.map(\.token) }
  }

  private func makeController(
    turnkey: MockTurnkey,
    configurationError: RainError? = nil,
    rpId: String? = nil
  ) -> TurnkeyManagedAuthController {
    Harness(turnkey: turnkey, configurationError: configurationError, rpId: rpId).controller
  }

  /// The mock context's hook for "a session now exists" after rain-api's login JWT is stored.
  private func installSessionOnStore(_ turnkey: MockTurnkey) {
    turnkey.onStoreSession = {
      turnkey.session = MockTurnkey.defaultSession()
      turnkey.authState = .authenticated
    }
  }

  // MARK: - Code login: send

  @Test("sendLoginCode mints a token bound to the contact and starts the code on rain-api")
  func testSendLoginCode() async throws {
    let h = Harness(turnkey: MockTurnkey(session: nil))

    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    #expect(h.tokenRequests == [.email("user@example.com")])
    #expect(h.api.calls == [.init(endpoint: .initOtp, token: "wat-1")])
  }

  @Test("sendLoginCode without a token provider throws invalidConfig before any call")
  func testSendLoginCodeWithoutTokenProvider() async {
    let h = Harness(turnkey: MockTurnkey(session: nil), tokenProvider: false)

    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await h.controller.sendLoginCode(to: .email("user@example.com"))
    }
    #expect(h.api.calls.isEmpty)
  }

  @Test("a token provider failure aborts the flow: a RainError as-is, anything else as providerError")
  func testTokenProviderFailure() async {
    let h = Harness(turnkey: MockTurnkey(session: nil))
    h.tokenProviderError = RainError.unauthorized(details: "backend says no")
    await #expect(throws: RainError.unauthorized()) {
      try await h.controller.sendLoginCode(to: .email("user@example.com"))
    }

    struct HostError: Error {}
    h.tokenProviderError = HostError()
    await #expect(throws: RainError.providerError(underlying: HostError())) {
      try await h.controller.sendLoginCode(to: .email("user@example.com"))
    }
    #expect(h.api.calls.isEmpty)
  }

  @Test("confirmLoginCode without a prior sendLoginCode throws invalidConfig")
  func testConfirmWithoutSend() async {
    let controller = makeController(turnkey: MockTurnkey(session: nil))

    await #expect(throws: RainError.self) {
      try await controller.confirmLoginCode("123456")
    }
  }

  // MARK: - Code login: confirm

  @Test("confirmLoginCode on a returning user: fresh key, encrypted code, verify, signed login, session stored under a per-attempt key")
  func testConfirmLoginCodeReturningUser() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    installSessionOnStore(turnkey)
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["user@example.com"] = "sub-existing"

    try await h.controller.sendLoginCode(to: .email("user@example.com"))
    try await h.controller.confirmLoginCode("123456")

    // One wallet auth token carried the whole flow; no signup for a known contact.
    #expect(h.api.endpoints == [.initOtp, .verifyOtp, .login])
    #expect(Set(h.tokens) == ["wat-1"])
    // A key pair per attempt; the code encrypted to it against the backend's bundle.
    #expect(turnkey.createdOtpKeys == ["otp-key-1"])
    #expect(turnkey.encryptOtpCalls == [.init(code: "123456", otpEncryptionTargetBundle: "bundle-1", publicKey: "otp-key-1")])
    #expect(h.api.verifyOtpBodies.map(\.otpId) == ["otp-1"])
    #expect(h.api.verifyOtpBodies.map(\.encryptedOtpBundle) == ["enc(123456)"])
    // The login message is signed with the key the verification token is bound to.
    #expect(turnkey.loginMessageCalls == ["vt-1"])
    #expect(turnkey.signClientMessageCalls == [.init(message: "login:vt-1", publicKey: "otp-key-1")])
    let login = try #require(h.api.loginBodies.first)
    #expect(login.verificationToken == "vt-1")
    #expect(login.clientSignature == RainApiClientSignature(publicKey: "otp-key-1", message: "login:vt-1", signature: "sig(login:vt-1)"))
    #expect(login.subOrganizationId == nil)
    // The session JWT lands under a per-attempt key; nothing to supersede, nothing cleared.
    let stored = try #require(turnkey.storeSessionCalls.first)
    #expect(stored.jwt == "jwt-1")
    #expect(stored.sessionKey.hasPrefix("rain-turnkey-"))
    #expect(turnkey.clearStoredSessionCalls.isEmpty)
    #expect(turnkey.selectStoredSessionCalls.isEmpty)
    #expect(turnkey.selectedStoredSessionKey == stored.sessionKey)
    // Both chain families already provisioned — nothing to create or derive.
    #expect(turnkey.createWalletCalls.isEmpty)
    #expect(turnkey.addAccountsCalls.isEmpty)
    #expect(h.controller.currentAuthState() == .authenticated)
  }

  @Test("a first login signs up on 404 and logs in again on the same token and verification token")
  func testConfirmLoginCodeSignsUpNewUser() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    installSessionOnStore(turnkey)
    let h = Harness(turnkey: turnkey)
    h.api.nextSubOrganizationId = "sub-new"

    try await h.controller.sendLoginCode(to: .email("user@example.com"))
    try await h.controller.confirmLoginCode("123456")

    #expect(h.api.endpoints == [.initOtp, .verifyOtp, .login, .signup, .login])
    #expect(Set(h.tokens) == ["wat-1"], "signup does not consume the token")
    #expect(h.tokenRequests.count == 1)
    // Signup names the contact only — rain-api provisions the seed and both accounts.
    #expect(turnkey.signupMessageCalls == [.init(verificationToken: "vt-1", email: "user@example.com", phoneNumber: nil)])
    let signup = try #require(h.api.signupBodies.first)
    #expect(signup.clientSignature.message == "signup:vt-1:user@example.com")
    // The second login carries the new sub-organization id and the same verification token.
    #expect(h.api.loginBodies.map(\.subOrganizationId) == [nil, "sub-new"])
    #expect(h.api.loginBodies.map(\.verificationToken) == ["vt-1", "vt-1"])
    #expect(turnkey.storeSessionCalls.count == 1)
    #expect(h.controller.currentAuthState() == .authenticated)
  }

  @Test("a wrong code is invalidLoginCode, keeps the challenge, and leaves a live session untouched")
  func testWrongCodeKeepsChallengeAndSession() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: MockTurnkey.defaultSession())
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["user@example.com"] = "sub-1"
    h.api.verifyOtpError = RainApiAuthError(kind: .invalidCode, statusCode: 400, message: "Invalid or expired code")
    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    await #expect(throws: RainError.invalidLoginCode) {
      try await h.controller.confirmLoginCode("999999")
    }
    #expect(turnkey.clearStoredSessionCalls.isEmpty)
    #expect(turnkey.storeSessionCalls.isEmpty)
    #expect(h.controller.hasActiveSession())

    // The retype goes straight to verify on the same token — no new code, a NEW key pair.
    h.api.verifyOtpError = nil
    try await h.controller.confirmLoginCode("123456")
    #expect(h.api.endpoints == [.initOtp, .verifyOtp, .verifyOtp, .login])
    #expect(turnkey.createdOtpKeys == ["otp-key-1", "otp-key-2"])
  }

  @Test("a failed verification ends the attempt: the next confirm needs a new code")
  func testVerificationFailedEndsAttempt() async throws {
    let h = Harness(turnkey: MockTurnkey(session: nil))
    h.api.verifyOtpError = RainApiAuthError(kind: .verificationFailed, statusCode: 400, message: "Verification failed")
    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    await #expect(throws: RainError.self) {
      try await h.controller.confirmLoginCode("123456")
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await h.controller.confirmLoginCode("123456")
    }
  }

  @Test("an expired token mid-flow is renewed from the host exactly once, never re-sending the code")
  func testExpiredTokenRenewedOnce() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    installSessionOnStore(turnkey)
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["user@example.com"] = "sub-1"
    try await h.controller.sendLoginCode(to: .email("user@example.com"))
    h.api.rejectedTokens = ["wat-1"]

    try await h.controller.confirmLoginCode("123456")

    #expect(h.api.calls.map(\.token) == ["wat-1", "wat-1", "wat-2", "wat-2"])
    #expect(h.api.endpoints == [.initOtp, .verifyOtp, .verifyOtp, .login])
    #expect(h.tokenRequests == [.email("user@example.com"), .email("user@example.com")])
  }

  @Test("a renewed token that is also rejected ends the attempt as unauthorized")
  func testRenewedTokenRejected() async throws {
    let h = Harness(turnkey: MockTurnkey(session: nil))
    try await h.controller.sendLoginCode(to: .email("user@example.com"))
    h.api.rejectedTokens = ["wat-1", "wat-2"]

    await #expect(throws: RainError.unauthorized()) {
      try await h.controller.confirmLoginCode("123456")
    }
    #expect(h.tokenRequests.count == 2)
  }

  @Test("a successful login over a live session activates the new key and drops only the old one")
  func testReloginSupersedesPreviousSession() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: MockTurnkey.defaultSession())
    let previousKey = try #require(turnkey.selectedStoredSessionKey)
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["other@example.com"] = "sub-2"

    try await h.controller.sendLoginCode(to: .email("other@example.com"))
    try await h.controller.confirmLoginCode("123456")

    let attemptKey = try #require(turnkey.storeSessionCalls.first?.sessionKey)
    // The vendor keeps the old session selected, so the new one is activated explicitly...
    #expect(turnkey.selectStoredSessionCalls == [attemptKey])
    #expect(turnkey.selectedStoredSessionKey == attemptKey)
    // ...and only the superseded key is purged — never the one just logged in under.
    #expect(turnkey.clearStoredSessionCalls == [previousKey])
    #expect(h.controller.hasActiveSession())
  }

  @Test("confirmLoginCode derives the missing Solana account from the existing wallet's seed")
  func testConfirmProvisionsMissingWallets() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.defaultWallet()], session: nil) // Ethereum only
    turnkey.onStoreSession = { turnkey.session = MockTurnkey.defaultSession() }
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["user@example.com"] = "sub-legacy"

    try await h.controller.sendLoginCode(to: .email("user@example.com"))
    try await h.controller.confirmLoginCode("123456")

    // Never a second wallet (a second seed to back up) — the account is derived on the
    // existing wallet.
    #expect(turnkey.createWalletCalls.isEmpty)
    #expect(turnkey.addAccountsCalls.count == 1)
    let call = try #require(turnkey.addAccountsCalls.first)
    #expect(call.walletId == "wallet-id")
    #expect(call.accounts.count == 1)
    #expect(call.accounts.first?.addressFormat == .address_format_solana)
    #expect(call.accounts.first?.curve == .curve_ed25519)
  }

  @Test("a signup that fails ends the attempt: nothing stored, the next confirm needs a new code")
  func testSignupFailureEndsAttempt() async throws {
    let turnkey = MockTurnkey(session: nil)
    let h = Harness(turnkey: turnkey)
    h.api.signupError = RainApiAuthError(kind: .conflict, statusCode: 409, message: "Signup in progress")
    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    let error = await #expect(throws: RainError.self) {
      try await h.controller.confirmLoginCode("123456")
    }
    #expect(error?.code == "RAIN_501")
    #expect(h.api.endpoints == [.initOtp, .verifyOtp, .login, .signup])
    #expect(turnkey.storeSessionCalls.isEmpty)
    #expect(h.controller.currentAuthState() == .unauthenticated)
    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await h.controller.confirmLoginCode("123456")
    }
  }

  @Test("a login that fails after verification ends the attempt without touching a live session")
  func testLoginFailureEndsAttempt() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.defaultSession())
    let h = Harness(turnkey: turnkey)
    h.api.loginError = RainApiAuthError(kind: .serverError, statusCode: 503, message: "Turnkey is not configured")
    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    await #expect(throws: RainError.self) {
      try await h.controller.confirmLoginCode("123456")
    }
    #expect(turnkey.storeSessionCalls.isEmpty)
    #expect(turnkey.clearStoredSessionCalls.isEmpty)
    #expect(h.controller.hasActiveSession(), "the previous session survives a failed login")
    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await h.controller.confirmLoginCode("123456")
    }
  }

  @Test("a signing failure on the device ends the attempt before any login call")
  func testSigningFailureEndsAttempt() async throws {
    let turnkey = MockTurnkey(session: nil)
    struct NoSuchKey: Error {}
    turnkey.signClientMessageError = NoSuchKey()
    let h = Harness(turnkey: turnkey)
    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    await #expect(throws: RainError.self) {
      try await h.controller.confirmLoginCode("123456")
    }
    #expect(h.api.endpoints == [.initOtp, .verifyOtp], "nothing reached /login")
    #expect(turnkey.storeSessionCalls.isEmpty)
  }

  @Test("a session the vendor refuses to store ends the attempt with nothing selected or cleared")
  func testStoreSessionFailureEndsAttempt() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.storeSessionError = TurnkeySwiftError.keyAlreadyExists
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["user@example.com"] = "sub-1"
    try await h.controller.sendLoginCode(to: .email("user@example.com"))

    await #expect(throws: RainError.self) {
      try await h.controller.confirmLoginCode("123456")
    }
    #expect(turnkey.selectStoredSessionCalls.isEmpty)
    #expect(turnkey.clearStoredSessionCalls.isEmpty)
    #expect(h.controller.currentAuthState() == .unauthenticated)
  }

  @Test("confirmLoginCode with no wallet at all creates one wallet with both accounts")
  func testConfirmCreatesSingleDualAccountWallet() async throws {
    let turnkey = MockTurnkey(wallets: [], session: nil)
    turnkey.onStoreSession = { turnkey.session = MockTurnkey.defaultSession() }
    let h = Harness(turnkey: turnkey)
    h.api.walletsByContact["user@example.com"] = "sub-empty"

    try await h.controller.sendLoginCode(to: .email("user@example.com"))
    try await h.controller.confirmLoginCode("123456")

    #expect(turnkey.createWalletCalls.count == 1)
    let call = try #require(turnkey.createWalletCalls.first)
    #expect(call.accounts.map(\.addressFormat) == [.address_format_ethereum, .address_format_solana])
    #expect(turnkey.addAccountsCalls.isEmpty)
  }

  @Test("a rain-api refusal surfaces as a mapped RainError, never raw")
  func testAuthErrorMapping() async {
    let h = Harness(turnkey: MockTurnkey(session: nil))
    h.api.initOtpError = RainApiAuthError(kind: .forbidden, statusCode: 403, message: "Feature not enabled")

    do {
      try await h.controller.sendLoginCode(to: .email("user@example.com"))
      Issue.record("Expected an error")
    } catch let error as RainError {
      #expect(error == .unauthorized())
    } catch {
      Issue.record("Expected RainError, got \(error)")
    }
  }

  @Test("a configuration mismatch makes every auth call throw invalidConfig")
  func testConfigurationErrorPropagates() async {
    let controller = makeController(
      turnkey: MockTurnkey(session: nil),
      configurationError: .invalidConfig(details: "mismatch")
    )

    await #expect(throws: RainError.invalidConfig(details: "mismatch")) {
      try await controller.sendLoginCode(to: .email("user@example.com"))
    }
  }

  // MARK: - State & session restore

  @Test("authState maps the vendor state to the Rain enum")
  func testAuthStateMapping() {
    let turnkey = MockTurnkey(session: nil)
    let controller = makeController(turnkey: turnkey)
    #expect(controller.currentAuthState() == .unauthenticated)

    turnkey.session = MockTurnkey.defaultSession()
    turnkey.authState = .authenticated
    #expect(controller.currentAuthState() == .authenticated)
  }

  @Test("hasActiveSession is true only for an unexpired session")
  func testHasActiveSession() {
    let turnkey = MockTurnkey(session: MockTurnkey.defaultSession())
    let controller = makeController(turnkey: turnkey)
    #expect(controller.hasActiveSession())

    turnkey.session = MockTurnkey.expiredSession()
    #expect(!controller.hasActiveSession())

    turnkey.session = nil
    #expect(!controller.hasActiveSession())
  }

  @Test("awaitSessionRestore backfills a missing account family on a restored session")
  func testRestoreBackfillsMissingAccounts() async throws {
    // A login that died between session storage and provisioning leaves a live session with an
    // EVM-only wallet; the restore path must repair it, since the OTP flow will be skipped.
    let turnkey = MockTurnkey(wallets: [MockTurnkey.defaultWallet()])
    let controller = makeController(turnkey: turnkey)

    await controller.awaitSessionRestore(timeout: 1)

    #expect(turnkey.addAccountsCalls.count == 1)
    #expect(turnkey.addAccountsCalls.first?.walletId == "wallet-id")
    #expect(turnkey.createWalletCalls.isEmpty)
  }

  @Test("awaitSessionRestore provisions nothing without a session or when accounts are complete")
  func testRestoreProvisionsOnlyWhenNeeded() async {
    let noSession = MockTurnkey(session: nil)
    await makeController(turnkey: noSession).awaitSessionRestore(timeout: 0.2)
    #expect(noSession.addAccountsCalls.isEmpty && noSession.createWalletCalls.isEmpty)

    let complete = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
    await makeController(turnkey: complete).awaitSessionRestore(timeout: 1)
    #expect(complete.addAccountsCalls.isEmpty && complete.createWalletCalls.isEmpty)
  }

  @Test("logout clears the stored session and the pending OTP")
  func testLogout() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.defaultSession())
    let controller = makeController(turnkey: turnkey)
    try await controller.sendLoginCode(to: .email("user@example.com"))

    await controller.logout()

    #expect(turnkey.clearStoredSessionCallCount == 1)
    // The mock flips live state from a main-actor Task like the vendor; logout must have waited.
    #expect(!controller.hasActiveSession())
    #expect(controller.currentAuthState() == .unauthenticated)
    await #expect(throws: RainError.self) {
      try await controller.confirmLoginCode("123456") // pending OTP was dropped
    }
  }

  // MARK: - SMS and contact normalization

  @Test("sendLoginCode to a phone number binds the token to the normalized E.164 number")
  func testSendLoginCodeSms() async throws {
    let h = Harness(turnkey: MockTurnkey(session: nil))

    try await h.controller.sendLoginCode(to: .phone(" +1 (555) 123-45.67 "))

    // The normalized string is the account identity — identical rule on Android. The device
    // never sends the contact; the token is bound to it.
    #expect(h.tokenRequests == [.phone("+15551234567")])
    #expect(h.api.endpoints == [.initOtp])
  }

  @Test("signup for a phone contact names the phone, not an email")
  func testSmsSignupMessage() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    installSessionOnStore(turnkey)
    let h = Harness(turnkey: turnkey)
    h.api.tokenContact = "+15551234567"

    try await h.controller.sendLoginCode(to: .phone("+1 555 123 4567"))
    try await h.controller.confirmLoginCode("123456")

    #expect(turnkey.signupMessageCalls == [.init(verificationToken: "vt-1", email: nil, phoneNumber: "+15551234567")])
  }

  @Test("an email is trimmed and lowercased before the token is minted")
  func testEmailTrimmedAndLowercased() async throws {
    let h = Harness(turnkey: MockTurnkey(session: nil))

    try await h.controller.sendLoginCode(to: .email("  User@Example.COM\n"))

    // The backend compares contacts byte-for-byte; mixed case would mint a second account.
    #expect(h.tokenRequests == [.email("user@example.com")])
  }

  @Test("the same inbox in different casing is one identity through signup")
  func testEmailCaseInsensitiveIdentity() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    installSessionOnStore(turnkey)
    let h = Harness(turnkey: turnkey)
    h.api.tokenContact = "volo@example.com"

    try await h.controller.sendLoginCode(to: .email("Volo@Example.com"))
    try await h.controller.confirmLoginCode("123456")

    #expect(turnkey.signupMessageCalls.first?.email == "volo@example.com")
  }

  @Test("contact verification attaches the lowercased email, not the raw input")
  func testContactVerificationLowercasesEmail() async throws {
    let h = Harness(turnkey: MockTurnkey(session: MockTurnkey.defaultSession()))

    try await h.controller.sendContactVerificationCode(to: .email("Second@Example.COM"))
    try await h.controller.confirmContactVerification("123456")

    #expect(h.tokenRequests == [.email("second@example.com")])
    #expect(h.turnkey.setUserEmailCalls.map(\.contact) == ["second@example.com"])
  }

  @Test(
    "an invalid contact throws invalidConfig locally, before a token is minted",
    arguments: [
      TurnkeyLoginContact.phone("5551234567"),      // no leading +: the country can't be guessed
      TurnkeyLoginContact.phone("+1555"),           // too short
      TurnkeyLoginContact.phone("+1555abc4567"),    // letters
      TurnkeyLoginContact.email("not-an-email"),    // no @
    ]
  )
  func testInvalidContactFailsFast(contact: TurnkeyLoginContact) async {
    let h = Harness(turnkey: MockTurnkey(session: nil))

    await #expect(throws: RainError.self) {
      try await h.controller.sendLoginCode(to: contact)
    }
    #expect(h.tokenRequests.isEmpty)
    #expect(h.api.calls.isEmpty)
  }

  @Test("contact verification attaches the normalized phone, not the raw input")
  func testContactVerificationNormalizes() async throws {
    let h = Harness(turnkey: MockTurnkey(session: MockTurnkey.defaultSession()))

    try await h.controller.sendContactVerificationCode(to: .phone("+1 (555) 123-4567"))
    try await h.controller.confirmContactVerification("123456")

    #expect(h.tokenRequests == [.phone("+15551234567")])
    #expect(h.turnkey.setUserPhoneNumberCalls.map(\.contact) == ["+15551234567"])
  }

  // MARK: - Passkeys

  @MainActor
  @Test("passkey login on a fresh install auto-selects the vendor's default-key session")
  func testPasskeyLoginFreshInstall() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.onPasskeyAuth = {
      turnkey.session = MockTurnkey.defaultSession()
      turnkey.authState = .authenticated
    }
    let controller = makeController(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    try await controller.loginWithPasskey(anchor: ASPresentationAnchor())

    #expect(turnkey.loginWithPasskeyCallCount == 1)
    // Nothing was selected, so the vendor auto-selected — no explicit activation.
    #expect(turnkey.selectStoredSessionCalls.isEmpty)
    #expect(turnkey.selectedStoredSessionKey == MockTurnkey.passkeyDefaultSessionKey)
    // The stale-default-key pre-purge is storage-only and touched no live state.
    #expect(turnkey.clearStoredSessionCalls == [MockTurnkey.passkeyDefaultSessionKey])
    #expect(controller.hasActiveSession())
  }

  @MainActor
  @Test("passkey login over a live OTP session activates the default key and drops the old one")
  func testPasskeyLoginOverOtpSession() async throws {
    let turnkey = MockTurnkey(
      wallets: [MockTurnkey.dualCurveWallet()],
      session: MockTurnkey.defaultSession() // selected under "previous-session-key"
    )
    let controller = makeController(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    try await controller.loginWithPasskey(anchor: ASPresentationAnchor())

    // The vendor kept the old session selected, so the passkey session (always under the
    // default key) is activated explicitly, then the superseded key is purged.
    #expect(turnkey.selectStoredSessionCalls == [MockTurnkey.passkeyDefaultSessionKey])
    #expect(turnkey.selectedStoredSessionKey == MockTurnkey.passkeyDefaultSessionKey)
    #expect(turnkey.clearStoredSessionCalls == [
      MockTurnkey.passkeyDefaultSessionKey, // storage-only pre-purge of the stale default key
      "previous-session-key",               // the superseded session
    ])
  }

  @MainActor
  @Test("passkey login and signup over a live passkey session are refused before the ceremony",
        arguments: [true, false])
  func testPasskeyOverLivePasskeySessionRefusedUpFront(signup: Bool) async throws {
    // The vendor stores the session LAST, so letting the ceremony run would mint a passkey (and
    // for signup an account) only to fail on the occupied default key. Refuse before Face ID.
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: MockTurnkey.defaultSession())
    turnkey.selectedStoredSessionKey = MockTurnkey.passkeyDefaultSessionKey
    turnkey.storedSessionKeys = [MockTurnkey.passkeyDefaultSessionKey]
    let controller = makeController(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    await #expect(throws: RainError.invalidConfig(details: "")) {
      if signup {
        try await controller.signUpWithPasskey(anchor: ASPresentationAnchor())
      } else {
        try await controller.loginWithPasskey(anchor: ASPresentationAnchor())
      }
    }

    #expect(turnkey.loginWithPasskeyCallCount == 0)
    #expect(turnkey.registerPasskeyCalls.isEmpty, "refused before Face ID")
    #expect(turnkey.clearStoredSessionCalls.isEmpty)
    #expect(turnkey.session != nil)
    #expect(controller.hasActiveSession())
  }

  @MainActor
  @Test("an expired session left under the selected default key is purged and passkey login proceeds")
  func testPasskeyLoginOverExpiredPasskeySessionProceeds() async throws {
    let turnkey = MockTurnkey(
      wallets: [MockTurnkey.dualCurveWallet()], session: MockTurnkey.session(expiringIn: -60)
    )
    turnkey.selectedStoredSessionKey = MockTurnkey.passkeyDefaultSessionKey
    turnkey.storedSessionKeys = [MockTurnkey.passkeyDefaultSessionKey]
    turnkey.onPasskeyAuth = {
      turnkey.session = MockTurnkey.defaultSession()
      turnkey.authState = .authenticated
    }
    let controller = makeController(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    try await controller.loginWithPasskey(anchor: ASPresentationAnchor())

    #expect(turnkey.loginWithPasskeyCallCount == 1)
    #expect(turnkey.clearStoredSessionCalls.first == MockTurnkey.passkeyDefaultSessionKey)
    #expect(controller.hasActiveSession())
  }

  @MainActor
  @Test("passkey signup: contact-less token, ceremony, /signup/passkey, then the vendor's passkey login")
  func testPasskeySignupOnRainApi() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.onPasskeyAuth = {
      turnkey.session = MockTurnkey.defaultSession()
      turnkey.authState = .authenticated
    }
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())

    // The token is minted for NO contact — the only token kind /signup/passkey accepts.
    #expect(h.tokenRequests == [nil])
    #expect(turnkey.registerPasskeyCalls == ["passkeys.rain.xyz"])
    #expect(h.api.calls == [.init(endpoint: .signupPasskey, token: "wat-1")])
    #expect(h.api.passkeyBodies == [turnkey.stubbedRegistration.apiAttestation])
    // Signup returns no session, so it comes from the vendor's passkey login (second prompt).
    #expect(turnkey.loginWithPasskeyCallCount == 1)
    #expect(turnkey.selectedStoredSessionKey == MockTurnkey.passkeyDefaultSessionKey)
    #expect(turnkey.selectStoredSessionCalls.isEmpty)
    #expect(turnkey.createWalletCalls.isEmpty)
    #expect(turnkey.addAccountsCalls.isEmpty)
    #expect(h.controller.currentAuthState() == .authenticated)
  }

  @MainActor
  @Test("passkey signup without a token provider fails before the ceremony")
  func testPasskeySignupWithoutTokenProvider() async {
    let turnkey = MockTurnkey(session: nil)
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz", tokenProvider: false)

    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(turnkey.registerPasskeyCalls.isEmpty, "no Face ID for a flow that cannot complete")
    #expect(h.api.calls.isEmpty)
  }

  @MainActor
  @Test("an expired token at /signup/passkey is renewed once, reusing the passkey already registered")
  func testPasskeySignupTokenRenewedOnce() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.onPasskeyAuth = { turnkey.session = MockTurnkey.defaultSession() }
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
    h.api.rejectedTokens = ["wat-1"]

    try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())

    #expect(turnkey.registerPasskeyCalls.count == 1, "one Face ID, not two look-alike passkeys")
    #expect(h.api.calls.map(\.token) == ["wat-1", "wat-2"])
    #expect(h.tokenRequests == [nil, nil])
    #expect(turnkey.loginWithPasskeyCallCount == 1)

    let again = Harness(turnkey: MockTurnkey(session: nil), rpId: "passkeys.rain.xyz")
    again.api.rejectedTokens = ["wat-1", "wat-2"]
    await #expect(throws: RainError.unauthorized()) {
      try await again.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(again.turnkey.loginWithPasskeyCallCount == 0)
  }

  @MainActor
  @Test("a signup whose outcome is unknown keeps the registration; the next tap resends it without a new ceremony")
  func testUnknownSignupOutcomeIsResent() async throws {
    for failure: Error in [
      RainApiAuthError(kind: .serverError, statusCode: 504, message: "upstream timeout"),
      URLError(.timedOut),
      RainApiAuthError(kind: .rateLimited, statusCode: 429, message: "Too many attempts"),
    ] {
      let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
      turnkey.onPasskeyAuth = { turnkey.session = MockTurnkey.defaultSession() }
      let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
      h.api.signupPasskeyError = failure

      await #expect(throws: RainError.self) {
        try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
      }
      #expect(h.pendingSignups.registration == turnkey.stubbedRegistration, "\(failure)")
      #expect(turnkey.loginWithPasskeyCallCount == 0)

      h.api.signupPasskeyError = nil
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())

      #expect(turnkey.registerPasskeyCalls.count == 1, "\(failure)")
      #expect(h.api.passkeyBodies.count == 2)
      #expect(h.api.passkeyBodies[0] == h.api.passkeyBodies[1])
      #expect(h.api.calls.map(\.token) == ["wat-1", "wat-2"])
      #expect(h.pendingSignups.registration == nil, "cleared once the account is known to exist")
      #expect(turnkey.loginWithPasskeyCallCount == 1)
    }
  }

  @MainActor
  @Test("a resend answered 'already has a wallet' means the first try landed: sign in, clear the registration")
  func testResendFindsTheEarlierAccount() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.onPasskeyAuth = { turnkey.session = MockTurnkey.defaultSession() }
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
    h.pendingSignups.registration = turnkey.stubbedRegistration // left by an earlier unknown outcome
    h.api.signupPasskeyError = RainApiAuthError(kind: .conflict, statusCode: 409, message: "Passkey already has a wallet")

    try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())

    #expect(turnkey.registerPasskeyCalls.isEmpty)
    #expect(turnkey.loginWithPasskeyCallCount == 1)
    #expect(h.pendingSignups.registration == nil)
    #expect(h.controller.hasActiveSession())
  }

  @MainActor
  @Test("a 409 'token has already been used' on a resend is a renewal, not 'the first try worked'")
  func testResendWithUsedTokenRenews() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.onPasskeyAuth = { turnkey.session = MockTurnkey.defaultSession() }
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
    h.pendingSignups.registration = turnkey.stubbedRegistration
    // First answer: the cached token was spent. Second (fresh token): success.
    h.api.signupPasskeyErrors = [
      RainApiAuthError(kind: .conflict, statusCode: 409, message: "This wallet auth token has already been used"),
    ]

    try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())

    #expect(h.api.calls.map(\.token) == ["wat-1", "wat-2"])
    #expect(h.api.passkeyBodies.count == 2, "the same registration resent on the fresh token")
    #expect(turnkey.registerPasskeyCalls.isEmpty)
    #expect(h.pendingSignups.registration == nil)
    #expect(turnkey.loginWithPasskeyCallCount == 1)
  }

  @MainActor
  @Test("a resend answered 'signup in progress' keeps the registration and asks the host to retry shortly")
  func testResendDuringBackendLock() async throws {
    let turnkey = MockTurnkey(session: nil)
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
    h.pendingSignups.registration = turnkey.stubbedRegistration
    h.api.signupPasskeyError = RainApiAuthError(kind: .conflict, statusCode: 409, message: "Signup in progress")

    do {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
      Issue.record("expected the in-progress error")
    } catch let error as RainError {
      guard case .providerError(let underlying) = error else {
        Issue.record("got \(error)")
        return
      }
      #expect(underlying is TurnkeyPasskeySignupInProgress)
    }
    #expect(turnkey.registerPasskeyCalls.isEmpty)
    #expect(turnkey.loginWithPasskeyCallCount == 0)
    #expect(h.pendingSignups.registration == turnkey.stubbedRegistration, "kept for the next try")
  }

  @MainActor
  @Test("a definitive refusal clears the registration, so the next tap runs a fresh ceremony")
  func testDefinitiveRefusalClearsRegistration() async throws {
    let turnkey = MockTurnkey(session: nil)
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
    h.api.signupPasskeyError = RainApiAuthError(kind: .forbidden, statusCode: 403, message: "Flag off")

    await #expect(throws: RainError.unauthorized()) {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(h.pendingSignups.saveCount == 1 && h.pendingSignups.registration == nil)

    h.api.signupPasskeyError = RainApiAuthError(kind: .forbidden, statusCode: 403, message: "Flag off")
    await #expect(throws: RainError.unauthorized()) {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(turnkey.registerPasskeyCalls.count == 2)
  }

  @Test("the persisted store round-trips a registration and clears it")
  func testUserDefaultsStoreRoundTrip() {
    let suite = "rain-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsPendingPasskeySignupStore(organizationId: "org-a", defaults: defaults)
    let registration = PasskeyRegistration(
      challenge: "c", credentialId: "id", clientDataJson: "cd", attestationObject: "ao",
      transports: ["AUTHENTICATOR_TRANSPORT_INTERNAL"]
    )
    #expect(store.load() == nil)
    store.save(registration)
    #expect(store.load() == registration)
    store.clear()
    #expect(store.load() == nil)
  }

  @Test("the persisted store keeps each organization's registration apart")
  func testUserDefaultsStoreIsPerOrganization() {
    let suite = "rain-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let sandbox = UserDefaultsPendingPasskeySignupStore(organizationId: "org-sandbox", defaults: defaults)
    let production = UserDefaultsPendingPasskeySignupStore(organizationId: "org-production", defaults: defaults)
    let registration = PasskeyRegistration(
      challenge: "c", credentialId: "id", clientDataJson: "cd", attestationObject: "ao",
      transports: ["AUTHENTICATOR_TRANSPORT_INTERNAL"]
    )
    sandbox.save(registration)
    #expect(production.load() == nil)
    production.clear()
    #expect(sandbox.load() == registration)
  }

  @MainActor
  @Test("a /signup/passkey refusal leaves no login attempt and steers a 409 to loginWithPasskey")
  func testPasskeySignupRefused() async {
    let turnkey = MockTurnkey(session: nil)
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")
    h.api.signupPasskeyError = RainApiAuthError(kind: .conflict, statusCode: 409, message: "Passkey already has a wallet")

    let error = await #expect(throws: RainError.self) {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(error?.code == "RAIN_102")
    #expect(error?.errorDescription?.contains("loginWithPasskey") == true)
    #expect(turnkey.loginWithPasskeyCallCount == 0)
    #expect(turnkey.clearStoredSessionCalls.isEmpty)

    h.api.signupPasskeyError = RainApiAuthError(kind: .forbidden, statusCode: 403, message: "Flag off")
    await #expect(throws: RainError.unauthorized()) {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(turnkey.loginWithPasskeyCallCount == 0)
  }

  @MainActor
  @Test("a cancelled ceremony surfaces as userRejected and never reaches rain-api")
  func testPasskeySignupCeremonyCancelled() async {
    let turnkey = MockTurnkey(session: nil)
    turnkey.registerPasskeyError = ASAuthorizationError(.canceled)
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    await #expect(throws: RainError.userRejected) {
      try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())
    }
    #expect(h.api.calls.isEmpty)
    #expect(turnkey.loginWithPasskeyCallCount == 0)
  }

  @MainActor
  @Test("passkey signup over a live OTP session activates the default key and drops the old one")
  func testPasskeySignupOverLiveOtpSession() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: MockTurnkey.defaultSession())
    let previousKey = try #require(turnkey.selectedStoredSessionKey)
    turnkey.onPasskeyAuth = { turnkey.session = MockTurnkey.defaultSession() }
    let h = Harness(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    try await h.controller.signUpWithPasskey(anchor: ASPresentationAnchor())

    #expect(turnkey.selectStoredSessionCalls == [MockTurnkey.passkeyDefaultSessionKey])
    #expect(turnkey.clearStoredSessionCalls == [MockTurnkey.passkeyDefaultSessionKey, previousKey])
    #expect(turnkey.selectedStoredSessionKey == MockTurnkey.passkeyDefaultSessionKey)
  }

  @MainActor
  @Test("passkey calls without a configured relying-party domain throw invalidConfig")
  func testPasskeyWithoutRpIdThrowsInvalidConfig() async {
    let turnkey = MockTurnkey(session: MockTurnkey.defaultSession())
    let controller = makeController(turnkey: turnkey) // rpId: nil

    let anchor = ASPresentationAnchor()
    await #expect(throws: RainError.self) {
      try await controller.loginWithPasskey(anchor: anchor)
    }
    await #expect(throws: RainError.self) {
      try await controller.signUpWithPasskey(anchor: anchor)
    }
    await #expect(throws: RainError.self) {
      try await controller.addPasskey(anchor: anchor)
    }
    #expect(turnkey.loginWithPasskeyCallCount == 0)
    #expect(turnkey.registerPasskeyCalls.isEmpty)
    #expect(turnkey.addPasskeyCalls.isEmpty)
  }

  @MainActor
  @Test("addPasskey registers an authenticator against the configured domain")
  func testAddPasskeyPassesRpId() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.defaultSession())
    let controller = makeController(turnkey: turnkey, rpId: "passkeys.rain.xyz")

    try await controller.addPasskey(anchor: ASPresentationAnchor())

    #expect(turnkey.addPasskeyCalls == ["passkeys.rain.xyz"])
  }

  // MARK: - Contact verification (attach a login contact)

  @Test("sendContactVerificationCode requires an active session")
  func testContactVerificationRequiresSession() async {
    let h = Harness(turnkey: MockTurnkey(session: nil))

    await #expect(throws: RainError.tokenExpired) {
      try await h.controller.sendContactVerificationCode(to: .email("new@example.com"))
    }
    #expect(h.tokenRequests.isEmpty)
  }

  @Test("confirmContactVerification verifies on rain-api with a token for the NEW contact and attaches it verified")
  func testAttachEmailContact() async throws {
    let turnkey = MockTurnkey(session: MockTurnkey.defaultSession())
    let h = Harness(turnkey: turnkey)
    h.api.challenge = RainApiOtpChallenge(otpId: "otp-9", otpEncryptionTargetBundle: "bundle-9")
    h.api.verificationToken = "vt-9"

    try await h.controller.sendContactVerificationCode(to: .email("new@example.com"))
    try await h.controller.confirmContactVerification("123456")

    #expect(h.tokenRequests == [.email("new@example.com")])
    #expect(h.api.endpoints == [.initOtp, .verifyOtp], "no login, no signup")
    #expect(turnkey.encryptOtpCalls == [.init(code: "123456", otpEncryptionTargetBundle: "bundle-9", publicKey: "otp-key-1")])
    // The token is what marks the contact VERIFIED — a login method, not just profile data.
    #expect(turnkey.setUserEmailCalls == [.init(contact: "new@example.com", verificationToken: "vt-9")])
    #expect(turnkey.setUserPhoneNumberCalls.isEmpty)
    // No login happened: the session machinery was never touched.
    #expect(turnkey.storeSessionCalls.isEmpty)
    #expect(turnkey.clearStoredSessionCalls.isEmpty)
  }

  @Test("confirmContactVerification attaches a verified phone number")
  func testAttachPhoneContact() async throws {
    let h = Harness(turnkey: MockTurnkey(session: MockTurnkey.defaultSession()))

    try await h.controller.sendContactVerificationCode(to: .phone("+15551234567"))
    try await h.controller.confirmContactVerification("123456")

    #expect(h.turnkey.setUserPhoneNumberCalls.map(\.contact) == ["+15551234567"])
    #expect(h.turnkey.setUserEmailCalls.isEmpty)
  }

  @Test("a wrong contact-verification code maps to invalidLoginCode and keeps the challenge")
  func testWrongContactVerificationCodeIsRetryable() async throws {
    let h = Harness(turnkey: MockTurnkey(session: MockTurnkey.defaultSession()))
    h.api.verifyOtpError = RainApiAuthError(kind: .invalidCode, statusCode: 400, message: "Invalid or expired code")
    try await h.controller.sendContactVerificationCode(to: .email("new@example.com"))

    await #expect(throws: RainError.invalidLoginCode) {
      try await h.controller.confirmContactVerification("999999")
    }

    // The challenge survives the wrong code: a retype succeeds without a new send.
    h.api.verifyOtpError = nil
    try await h.controller.confirmContactVerification("123456")
    #expect(h.api.endpoints == [.initOtp, .verifyOtp, .verifyOtp])
    #expect(h.turnkey.setUserEmailCalls.map(\.contact) == ["new@example.com"])
  }

  // MARK: - Key export

  @Test("exportMnemonic exports the account's single wallet seed")
  func testExportMnemonic() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
    let controller = makeController(turnkey: turnkey)

    let phrase = try await controller.exportMnemonic()

    #expect(phrase == turnkey.stubbedMnemonic)
    #expect(turnkey.exportMnemonicCalls == ["wallet-id"])
    // Wallets were already loaded; no extra refresh round-trip.
    #expect(turnkey.refreshWalletsCallCount == 0)
  }

  @Test("exportMnemonic refreshes an empty wallet cache before resolving the wallet")
  func testExportMnemonicRefreshesWhenEmpty() async throws {
    let turnkey = MockTurnkey(wallets: [])
    turnkey.onRefreshWallets = { turnkey.wallets = [MockTurnkey.dualCurveWallet()] }
    let controller = makeController(turnkey: turnkey)

    _ = try await controller.exportMnemonic()

    #expect(turnkey.refreshWalletsCallCount == 1)
    #expect(turnkey.exportMnemonicCalls == ["wallet-id"])
  }

  @Test("exportMnemonic anchors on the wallet holding the Ethereum account (legacy two-seed accounts)")
  func testExportMnemonicLegacyTwoWallets() async throws {
    // Pre one-seed accounts hold two wallets/seeds. The phrase must come from the wallet whose
    // Ethereum key is in use, or it derives a different address than the exported private key.
    let turnkey = MockTurnkey(wallets: [MockTurnkey.solanaOnlyWallet(), MockTurnkey.defaultWallet()])
    let controller = makeController(turnkey: turnkey)

    _ = try await controller.exportMnemonic()

    #expect(turnkey.exportMnemonicCalls == ["wallet-id"]) // the Ethereum wallet, not "wallet-id-sol"
  }

  @Test("exportPrivateKey resolves the right account and encoding per family")
  func testExportPrivateKeyPerFamily() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
    let controller = makeController(turnkey: turnkey)

    let ethKey = try await controller.exportPrivateKey(family: .ethereum)
    let solKey = try await controller.exportPrivateKey(family: .solana)

    #expect(turnkey.exportAccountKeyCalls == [
      .init(address: MockTurnkey.defaultWalletAddress, encoding: .hexSecp256k1),
      .init(address: MockTurnkey.defaultSolanaAddress, encoding: .solanaBase58),
    ])
    // Ethereum keys carry the 0x prefix at the Rain boundary; Solana Base58 passes through.
    #expect(ethKey == "0x" + turnkey.stubbedExportedKey)
    #expect(solKey == turnkey.stubbedExportedKey)
  }

  @Test("exportPrivateKey for a family with no account throws a mapped error")
  func testExportPrivateKeyMissingFamily() async {
    // EVM-only wallet (predates dual-account provisioning): no Solana account to export.
    let turnkey = MockTurnkey(wallets: [MockTurnkey.defaultWallet()])
    let controller = makeController(turnkey: turnkey)

    await #expect(throws: RainError.self) {
      _ = try await controller.exportPrivateKey(family: .solana)
    }
    #expect(turnkey.exportAccountKeyCalls.isEmpty)
  }

  @Test("SolanaKeyEncoder emits the plain-Base58 keypair Solana wallets import")
  func testSolanaKeyEncoderVector() throws {
    // Known vector (PyNaCl/libsodium): priv = 0x01…20, plain Base58 of priv‖pub, NO checksum —
    // the vendor's Base58Check output is rejected by Phantom, hence this encoder.
    let encoded = try SolanaKeyEncoder.keypairBase58(
      privateKeyHex: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    )
    #expect(encoded == "2Ana1pUpv2ZbMVkwF5FXapYeBEjdxDatLn7nvJkhgTSdZd8hbDHTd21as7EAsg7ypityqfsw2pMQKJcVDVcAEsd")
  }

  @Test("SolanaKeyEncoder rejects malformed key material")
  func testSolanaKeyEncoderRejectsBadInput() {
    #expect(throws: (any Error).self) {
      _ = try SolanaKeyEncoder.keypairBase58(privateKeyHex: "abcd") // not 32 bytes
    }
    #expect(throws: (any Error).self) {
      _ = try SolanaKeyEncoder.keypairBase58(privateKeyHex: "zz") // not hex
    }
  }

  @Test("export with no session surfaces a mapped RainError, never raw")
  func testExportWithoutSessionMapsError() async {
    let turnkey = MockTurnkey(wallets: [], session: nil)
    let controller = makeController(turnkey: turnkey)

    do {
      _ = try await controller.exportMnemonic()
      Issue.record("Expected exportMnemonic to throw")
    } catch {
      #expect(error is RainError)
    }
  }

  @Test("a vendor export failure surfaces as a mapped RainError, never raw")
  func testExportVendorErrorMapsError() async {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
    turnkey.exportMnemonicError = TurnkeySwiftError.failedToExportWallet(
      underlying: TurnkeyRequestError.apiError(statusCode: 500, payload: nil)
    )
    let controller = makeController(turnkey: turnkey)

    do {
      _ = try await controller.exportMnemonic()
      Issue.record("Expected exportMnemonic to throw")
    } catch {
      #expect(error is RainError)
    }
  }

  // MARK: - Provider surface

  private static let testBackend = TurnkeyManagedAuthBackend(
    baseURL: URL(string: "https://api-dev.rain.xyz")!,
    tokenProvider: { _ in "wat-test" }
  )

  @Test("auth methods on a BYO-mode provider throw invalidConfig")
  func testByoModeGuard() async {
    let provider = TurnkeyProvider(
      config: TurnkeyConfig(organizationId: "org", authProxyConfigId: "proxy", authBackend: Self.testBackend),
      context: MockTurnkey(session: nil),
      managedAuth: nil // what a BYO construction yields
    )

    #expect(provider.currentAuthState() == .unauthenticated)
    #expect(!provider.hasActiveSession())
    await #expect(throws: RainError.self) {
      try await provider.sendLoginCode(to: .email("user@example.com"))
    }
    await #expect(throws: RainError.self) {
      _ = try await provider.exportMnemonic()
    }
    await #expect(throws: RainError.self) {
      _ = try await provider.exportPrivateKey(family: .ethereum)
    }
  }

  @Test("managed provider forwards the code flow to the controller")
  func testManagedProviderForwards() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()], session: nil)
    turnkey.onStoreSession = { turnkey.session = MockTurnkey.defaultSession() }
    let api = MockRainApiAuthClient()
    api.walletsByContact["user@example.com"] = "sub-1"
    let provider = TurnkeyProvider(
      config: TurnkeyConfig(organizationId: "org", authProxyConfigId: "proxy", authBackend: Self.testBackend),
      context: turnkey,
      managedAuth: TurnkeyManagedAuthController(
        context: turnkey, configurationError: nil, api: api, tokenProvider: Self.testBackend.tokenProvider,
        pendingPasskeySignups: InMemoryPendingPasskeySignupStore()
      )
    )

    try await provider.sendLoginCode(to: .email("user@example.com"))
    try await provider.confirmLoginCode("123456")

    #expect(api.endpoints == [.initOtp, .verifyOtp, .login])
    #expect(turnkey.storeSessionCalls.count == 1)
    #expect(provider.hasActiveSession())
  }

  // MARK: - Process-wide configurator

  @Test("configure is idempotent for identical ids and errors on different ids")
  func testConfigurator() {
    // Unique ids per run: the configurator is process-global state.
    let organizationId = "org-\(UUID().uuidString)"
    let previousImpl = TurnkeyManagedConfigurator.configureImpl
    defer { TurnkeyManagedConfigurator.configureImpl = previousImpl }
    nonisolated(unsafe) var configureCalls = 0
    TurnkeyManagedConfigurator.configureImpl = { _, _, _ in configureCalls += 1 }

    #expect(TurnkeyManagedConfigurator.configure(organizationId: organizationId, authProxyConfigId: "p", rpId: nil) == nil)
    #expect(TurnkeyManagedConfigurator.configure(organizationId: organizationId, authProxyConfigId: "p", rpId: nil) == nil)
    #expect(configureCalls == 1)
    #expect(TurnkeyManagedConfigurator.configure(organizationId: "other", authProxyConfigId: "p", rpId: nil) != nil)
  }
}
