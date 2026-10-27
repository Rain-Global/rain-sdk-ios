import AuthenticationServices
import Combine
import Foundation
import TurnkeySwift
import TurnkeyTypes
import RainCore

// MARK: - Auth state

/// Where managed Turnkey authentication stands, at the Rain boundary.
/// Not public API — `@_spi(RainWallet)`, surfaced to hosts only through `RainWalletAuthState`.
@_spi(RainWallet)
public enum TurnkeyAuthState: Sendable, Equatable {
  /// The SDK is still restoring a possible previous session from secure storage.
  case loading
  /// A session is active; the provider can be resolved and wallet calls will succeed.
  case authenticated
  /// No session; run `sendLoginCode` / `confirmLoginCode`.
  case unauthenticated

  internal init(_ vendorState: AuthState) {
    switch vendorState {
    case .authenticated: self = .authenticated
    case .unAuthenticated: self = .unauthenticated
    default: self = .loading
    }
  }
}

// MARK: - Login contact

/// Where a one-time login code is delivered.
/// Not public API — `@_spi(RainWallet)`, surfaced to hosts through RainWallet's neutral enum.
@_spi(RainWallet)
public enum TurnkeyLoginContact: Sendable, Equatable {
  /// Email OTP.
  case email(String)
  /// SMS OTP. Requires SMS auth to be enabled on the wallet backend (Turnkey Enterprise
  /// feature on Rain's organization).
  case phone(String)

  internal var contact: String {
    switch self {
    case .email(let value), .phone(let value): value
    }
  }

  internal var otpType: OtpType {
    switch self {
    case .email: .email
    case .phone: .sms
    }
  }

  /// The contact normalized for the wallet backend: emails are trimmed and lowercased; phone
  /// numbers have user-visible formatting (spaces, dashes, dots, parentheses) stripped down to
  /// E.164. Throws `invalidConfig` when what remains cannot be a valid contact — a clear local
  /// error beats a wrapped backend rejection. Identical rules on the Android SDK: the normalized
  /// string is the account identity, so both platforms must produce the same one.
  ///
  /// Lowercasing is deliberate: the wallet backend compares contacts byte-for-byte, so
  /// `Volo@example.com` and `volo@example.com` would be two accounts with two empty wallets.
  /// RFC 5321 lets a mailbox be case-sensitive in its local part, but no mail provider is, and
  /// one identity per inbox is what users expect (beta finding 2026-10-05).
  internal func normalized() throws -> TurnkeyLoginContact {
    switch self {
    case .email(let raw):
      let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard email.contains("@"), email.count >= 3 else {
        throw RainError.invalidConfig(details: "Not a valid email address")
      }
      return .email(email)
    case .phone(let raw):
      let formatting = CharacterSet(charactersIn: "-.()").union(.whitespacesAndNewlines)
      let phone = String(String.UnicodeScalarView(
        raw.unicodeScalars.filter { !formatting.contains($0) }
      ))
      // E.164: a leading "+" and 6–15 digits, nothing else.
      let digits = phone.dropFirst()
      guard phone.hasPrefix("+"),
            (6...15).contains(digits.count),
            digits.allSatisfy({ $0.isASCII && $0.isNumber })
      else {
        throw RainError.invalidConfig(details:
          "Not a valid phone number — use the international format, like +15551234567")
      }
      return .phone(phone)
    }
  }
}

// MARK: - Auth backend (rain-api)

/// Where managed auth talks to Rain's backend, and how it obtains the wallet auth token that
/// every device call rides on. Not public API — `@_spi(RainWallet)`, surfaced through
/// `RainWalletConfig(environment:authTokenProvider:)`.
///
/// The token (`wat_…`) is minted by the PARTNER'S BACKEND with its Rain Api-Key: ten-minute TTL,
/// bound to one contact (or to none, for passkey signup), consumed by login. The SDK asks
/// `tokenProvider` for one at the start of each code flow — login, or attaching a contact — and
/// once more if the backend reports the token expired mid-flow. `nil` means the host has not
/// wired a backend: the code flows throw `invalidConfig`, passkey login still works.
@_spi(RainWallet)
public struct TurnkeyManagedAuthBackend: @unchecked Sendable {
  public typealias TokenProvider = @Sendable (TurnkeyLoginContact?) async throws -> String

  public let baseURL: URL
  public let tokenProvider: TokenProvider?

  public init(baseURL: URL, tokenProvider: TokenProvider?) {
    self.baseURL = baseURL
    self.tokenProvider = tokenProvider
  }
}

/// rain-api is still finishing (or holding a 120-second lock after) an earlier attempt to create
/// this passkey's account. The registration is kept; call `signUpWithPasskey` again shortly and
/// the SDK resends it without a new Face ID prompt.
internal struct TurnkeyPasskeySignupInProgress: LocalizedError, Equatable {
  let message: String
  var errorDescription: String? {
    "Passkey signup is still in progress on the backend — try again in a couple of minutes (\(message))"
  }
}

// MARK: - Key export

/// Chain-family selector for a single-key export.
/// Not public API — `@_spi(RainWallet)`, surfaced to hosts through RainWallet's neutral enum.
@_spi(RainWallet)
public enum TurnkeyKeyFamily: Sendable, Equatable {
  /// secp256k1; exports as a 0x-prefixed 32-byte hex string.
  case ethereum
  /// ed25519; exports as plain Base58 of privkey‖pubkey (no checksum), the format Solana wallets import.
  case solana
}

// MARK: - Process-wide configuration

/// Guards `TurnkeyContext.configure(...)`, which is one-shot for the process lifetime.
/// Configuring again with the same values is a no-op; with different values it is an error the
/// caller must surface (the app has to relaunch to change them).
///
/// The rain-api base URL joins the key even though the vendor never sees it: two providers for
/// different environments would share the one vendor session store, so a sandbox login could be
/// picked up by a production provider. Android keys the same guard on all three.
internal enum TurnkeyManagedConfigurator {
  nonisolated(unsafe) private static var configuredWith:
    (organizationId: String, rpId: String?, authBaseURL: URL)?
  private static let lock = NSLock()

  /// Test seam: replaces the actual vendor configure call.
  nonisolated(unsafe) internal static var configureImpl: @Sendable (String, String?) -> Void = { organizationId, rpId in
    // No auth-proxy configuration: code login, signup and contact attach run against rain-api,
    // and passkey login builds its own passkey-stamped client. Without the proxy id the
    // vendor's `client` is nil until a session exists — every call the SDK makes already runs
    // behind the session guard, so nothing observes that.
    TurnkeyContext.configure(
      TurnkeySwift.TurnkeyConfig(
        organizationId: organizationId,
        authProxyConfigId: nil,
        rpId: rpId
      )
    )
  }

  /// Test seam: how a managed provider obtains the process-wide context. The vendor's `.shared`
  /// traps when unconfigured, so tests replace this rather than ever touching the real singleton.
  nonisolated(unsafe) internal static var sharedContext: @Sendable () -> TurnkeyContextProtocol = {
    TurnkeyContext.shared
  }

  /// Configures the Turnkey singleton once per process. Returns the error to surface on every
  /// subsequent call when the values differ from the ones the process was configured with.
  /// `rpId` is the passkey relying-party domain; `nil` disables passkey flows. `authBaseURL` is
  /// the rain-api environment the provider authenticates against.
  internal static func configure(
    organizationId: String,
    rpId: String?,
    authBaseURL: URL
  ) -> RainError? {
    lock.lock(); defer { lock.unlock() }
    if let configuredWith {
      guard configuredWith == (organizationId, rpId, authBaseURL) else {
        return .invalidConfig(details:
          "The wallet backend is already configured for this app launch with a different "
          + "passkey domain or environment; relaunch the app to change them")
      }
      return nil
    }
    configureImpl(organizationId, rpId)
    configuredWith = (organizationId, rpId, authBaseURL)
    return nil
  }
}

// MARK: - Managed auth controller

/// Owns the email-OTP flow for a managed-mode `TurnkeyProvider`: send code, confirm code
/// (signup-or-login), wallet provisioning, logout, and session restore. All vendor errors are
/// mapped to `RainError` before they surface.
internal final class TurnkeyManagedAuthController: @unchecked Sendable {
  private let context: TurnkeyContextProtocol
  /// Set when the process was already configured with different values; every call fails with it.
  private let configurationError: RainError?
  /// rain-api's device endpoints.
  private let api: any RainApiAuthClientProtocol
  /// Mints the wallet auth token each code flow rides on; `nil` = no backend wired by the host.
  private let tokenProvider: TurnkeyManagedAuthBackend.TokenProvider?
  /// A passkey registration whose `/signup/passkey` outcome is unknown, kept so the next signup
  /// resends it instead of minting a second passkey (see `PendingPasskeySignupStore`).
  private let pendingPasskeySignups: any PendingPasskeySignupStore

  /// One code flow in flight: the token it rides on, the challenge rain-api issued, and the
  /// normalized contact the token is bound to.
  internal struct PendingCode {
    var token: String
    let challenge: RainApiOtpChallenge
    let contact: TurnkeyLoginContact
  }

  /// In-flight code handed back by `sendLoginCode`, consumed by `confirmLoginCode`.
  private var pendingOtp: PendingCode?
  /// In-flight code for contact verification (attach a login contact to the current account) —
  /// deliberately separate from `pendingOtp` so a login flow can't consume a verification code.
  private var pendingContactVerification: PendingCode?
  private let pendingOtpLock = NSLock()

  /// The passkey relying-party domain from the managed configuration; `nil` means passkeys are
  /// not configured and every passkey call throws `invalidConfig`.
  private let rpId: String?

  /// At swift-sdk 4.0.0 the vendor pins every passkey session to this key — the `sessionKey`
  /// parameters on its passkey flows are accepted but ignored — and refuses to overwrite an
  /// occupied key. See the passkey methods for the resulting session handling.
  internal static let passkeyDefaultSessionKey = "com.turnkey.sdk.session"

  /// Minimum remaining lifetime (seconds) for a restored session to count as active.
  private static let sessionMinRemainingSeconds: TimeInterval = 30

  /// The account set every Rain user gets, derived from ONE wallet seed (standard first-index
  /// derivation paths). A single seed per user is a cross-platform contract with the Android SDK:
  /// one phrase to back up and export, regardless of chain family.
  internal static let ethereumAccount = WalletAccountParams(
    addressFormat: .address_format_ethereum,
    curve: .curve_secp256k1,
    path: "m/44'/60'/0'/0/0",
    pathFormat: .path_format_bip32
  )
  internal static let solanaAccount = WalletAccountParams(
    addressFormat: .address_format_solana,
    curve: .curve_ed25519,
    path: "m/44'/501'/0'/0'",
    pathFormat: .path_format_bip32
  )

  internal init(
    context: TurnkeyContextProtocol,
    configurationError: RainError?,
    rpId: String? = nil,
    api: any RainApiAuthClientProtocol,
    tokenProvider: TurnkeyManagedAuthBackend.TokenProvider?,
    pendingPasskeySignups: any PendingPasskeySignupStore
  ) {
    self.context = context
    self.configurationError = configurationError
    self.rpId = rpId
    self.api = api
    self.tokenProvider = tokenProvider
    self.pendingPasskeySignups = pendingPasskeySignups
  }

  // MARK: State

  internal func currentAuthState() -> TurnkeyAuthState {
    TurnkeyAuthState(context.authState)
  }

  internal var authState: AnyPublisher<TurnkeyAuthState, Never> {
    context.authStatePublisher.map(TurnkeyAuthState.init).removeDuplicates().eraseToAnyPublisher()
  }

  /// True when an unexpired session is already loaded (restored from secure storage), so the
  /// OTP flow can be skipped.
  internal func hasActiveSession() -> Bool {
    guard let session = context.session else { return false }
    return session.exp > Date().timeIntervalSince1970 + Self.sessionMinRemainingSeconds
  }

  /// The session restore after configuration is asynchronous; waits until it settles (a session
  /// appears or the state resolves to unauthenticated) or `timeout` elapses. A restored session
  /// also gets wallet provisioning re-checked (see below).
  internal func awaitSessionRestore(timeout: TimeInterval) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if context.session != nil || context.authState == .unAuthenticated { break }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    // A previous login can have died between session storage and wallet provisioning (e.g. a
    // network blip in ensureWallets after completeOtp succeeded): the session is live, the host
    // skips the OTP flow, and confirmLoginCode — the only other place provisioning runs — never
    // executes again, stranding the account without one of its chain families. Re-check here,
    // best-effort: a failure simply retries on the next restore, and the check is a no-op when
    // both accounts exist.
    if hasActiveSession() {
      try? await ensureWallets()
    }
  }

  // MARK: One-time-code login (email or SMS)

  /// Asks the host's backend for a wallet auth token bound to `contact` (nil = contact-less,
  /// passkey signup only). `invalidConfig` when the host wired no backend.
  private func mintToken(for contact: TurnkeyLoginContact?) async throws -> String {
    guard let tokenProvider else {
      throw RainError.invalidConfig(details:
        "No wallet auth token provider is configured — pass `authTokenProvider` in the Rain "
        + "wallet configuration (your backend mints it with your Rain Api-Key)")
    }
    do {
      return try await tokenProvider(contact)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RainError {
      throw error
    } catch {
      throw RainError.providerError(underlying: error)
    }
  }

  /// Runs one rain-api call that rides on `pending.token`; if the backend reports the token
  /// expired or revoked, mints one more from the host and retries ONCE. A 401 "Invalid tenant"
  /// is classified as `.forbidden`, not `.tokenRejected`, so it never reaches here.
  private func withTokenRetry<T>(
    _ pending: inout PendingCode,
    _ call: (String) async throws -> T
  ) async throws -> T {
    do {
      return try await call(pending.token)
    } catch let error as RainApiAuthError where error.kind == .tokenRejected {
      pending.token = try await mintToken(for: pending.contact)
      return try await call(pending.token)
    }
  }

  internal func sendLoginCode(to contact: TurnkeyLoginContact) async throws {
    try throwIfMisconfigured()
    // The normalized string is the account identity — it is what the token is bound to, what
    // signup records, and what the next login must normalize to again.
    let contact = try contact.normalized()
    let token = try await mintToken(for: contact)
    do {
      let challenge = try await api.initOtp(token: token)
      pendingOtpLock.withLock {
        pendingOtp = PendingCode(token: token, challenge: challenge, contact: contact)
      }
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// Confirms the code from `sendLoginCode`. The device does what the vendor's proxy flow did:
  /// a fresh key pair, the code encrypted to it, the verification token exchanged for a session
  /// with a client signature. Login-or-signup is decided by rain-api's answer — a 404 means no
  /// wallet for this contact in this tenant, so the account is signed up (rain-api provisions
  /// one seed with the Ethereum and Solana accounts) and logged in on the same token. Then the
  /// account's accounts are re-checked (backfill for legacy seeds).
  internal func confirmLoginCode(_ code: String) async throws {
    try throwIfMisconfigured()
    guard var pending = pendingOtpLock.withLock({ pendingOtp }) else {
      throw RainError.invalidConfig(details: "No login code was requested; call sendLoginCode first")
    }

    let verificationToken: String
    do {
      // Fresh per attempt: the verification token is bound to this key, and a retyped code
      // must not reuse a key a failed attempt already bound.
      let publicKey = try context.createOtpKeyPair()
      let encrypted = try context.encryptOtpCode(
        code,
        otpEncryptionTargetBundle: pending.challenge.otpEncryptionTargetBundle,
        publicKey: publicKey
      )
      let otpId = pending.challenge.otpId
      verificationToken = try await withTokenRetry(&pending) { token in
        try await api.verifyOtp(token: token, otpId: otpId, encryptedOtpBundle: encrypted)
      }.verificationToken
    } catch let error as RainApiAuthError where error.kind == .invalidCode {
      // The challenge survives a mistyped code: the user retypes, no new code is sent.
      pendingOtpLock.withLock { pendingOtp = pending }
      throw RainError.invalidLoginCode
    } catch {
      // Verification failed for good (or the token could not be renewed): the attempt is over,
      // the user requests a new code. Nothing was stored, a live session stays live.
      pendingOtpLock.withLock { pendingOtp = nil }
      throw RainError.from(underlying: error)
    }

    let login: RainApiLogin
    do {
      login = try await loginOrSignUp(&pending, verificationToken: verificationToken)
    } catch {
      pendingOtpLock.withLock { pendingOtp = nil }
      throw RainError.from(underlying: error)
    }

    // Store under a fresh per-attempt session key: the vendor refuses only a same-key
    // collision, so an already-active session survives until the new one is selected.
    // Mirrors the Android SDK's behaviour.
    let attemptKey = Self.newAttemptSessionKey()
    let previousKey = context.selectedStoredSessionKey
    do {
      try await context.storeTurnkeySession(jwt: login.sessionToken, sessionKey: attemptKey)
    } catch {
      pendingOtpLock.withLock { pendingOtp = nil }
      throw RainError.from(underlying: error)
    }
    try await activateStoredSession(attemptKey: attemptKey, previousKey: previousKey)
    pendingOtpLock.withLock { pendingOtp = nil }
    do {
      try await ensureWallets()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// `/login`, and on 404 `/signup` then `/login` again — same wallet auth token (signup does
  /// not consume it), same verification token. Each call gets its own signature over its own
  /// message; both messages name the key the verification token is bound to.
  private func loginOrSignUp(
    _ pending: inout PendingCode,
    verificationToken: String
  ) async throws -> RainApiLogin {
    let (loginMessage, publicKey) = try context.clientSignatureForLogin(verificationToken: verificationToken)
    let loginSignature = RainApiClientSignature(
      publicKey: publicKey,
      message: loginMessage,
      signature: try await context.signClientMessage(loginMessage, publicKey: publicKey)
    )
    do {
      return try await withTokenRetry(&pending) { token in
        try await api.login(
          token: token, verificationToken: verificationToken,
          clientSignature: loginSignature, subOrganizationId: nil
        )
      }
    } catch let error as RainApiAuthError where error.kind == .noWallet {
      // First login for this contact in this tenant.
    }

    let (email, phone): (String?, String?) = switch pending.contact {
    case .email(let value): (value, nil)
    case .phone(let value): (nil, value)
    }
    let (signupMessage, signupKey) = try context.clientSignatureForSignup(
      verificationToken: verificationToken, email: email, phoneNumber: phone
    )
    let signupSignature = RainApiClientSignature(
      publicKey: signupKey,
      message: signupMessage,
      signature: try await context.signClientMessage(signupMessage, publicKey: signupKey)
    )
    let signup = try await withTokenRetry(&pending) { token in
      try await api.signup(token: token, verificationToken: verificationToken, clientSignature: signupSignature)
    }
    return try await withTokenRetry(&pending) { token in
      try await api.login(
        token: token, verificationToken: verificationToken,
        clientSignature: loginSignature, subOrganizationId: signup.subOrganizationId
      )
    }
  }

  // MARK: Passkeys

  /// Signs an existing user in with a passkey. Provisioning is re-checked afterwards (backfill
  /// for accounts predating one-seed provisioning).
  internal func loginWithPasskey(anchor: ASPresentationAnchor) async throws {
    try throwIfMisconfigured()
    try requirePasskeysConfigured()
    try await refuseIfLivePasskeySession()
    let previousKey = context.selectedStoredSessionKey
    preparePasskeyDefaultKey()
    do {
      try await context.loginWithTurnkeyPasskey(anchor: anchor, organizationId: nil)
    } catch {
      // Nothing was stored or cleared beyond a stale unselected key — a live session stays live.
      throw RainError.from(underlying: error)
    }
    try await activatePasskeySession(previousKey: previousKey)
    do {
      try await ensureWallets()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// Creates a NEW account with a passkey: the registration ceremony (one biometric prompt),
  /// `/signup/passkey` on a contact-less wallet auth token, then a session stamped with the
  /// temporary key rain-api attached to the new account. When that key cannot open the session
  /// (rain-api adopted an earlier unsaved attempt and attached none, the 60 s passed, or the
  /// stamp failed) the vendor's passkey login runs instead, scoped to the returned account.
  /// Refused over any live session; returning users use `loginWithPasskey` or a login code.
  ///
  /// Failure residue: the token is minted before the ceremony, so a host without a backend
  /// fails before Face ID. An unknown signup outcome (timeout, transport, 5xx, 429) keeps the
  /// persisted registration and the next call resends it — rain-api may have created the
  /// account past our timeout and records it only on a resend of the same credential. A
  /// definitive refusal clears it. A login failure after a successful signup leaves an account
  /// the same passkey opens with `loginWithPasskey`.
  internal func signUpWithPasskey(anchor: ASPresentationAnchor) async throws {
    try throwIfMisconfigured()
    let rpId = try requirePasskeysConfigured()
    // A second tap or host retry would otherwise mint an empty second account.
    if hasActiveSession() {
      throw RainError.invalidConfig(details: "Already signed in; log out before creating a new account")
    }
    try await refuseIfLivePasskeySession() // purges an expired default-key session
    let token = try await mintToken(for: nil)

    let registration: PasskeyRegistration
    let resuming: Bool
    if let pending = pendingPasskeySignups.load() {
      registration = pending
      resuming = true
    } else {
      do {
        registration = try await context.registerPasskey(anchor: anchor, rpId: rpId)
      } catch {
        throw RainError.from(underlying: error)
      }
      // Saved BEFORE the call: an unknown outcome must find it here.
      pendingPasskeySignups.save(registration)
      resuming = false
    }

    let loginKey = context.makeTemporaryApiKey()
    let subOrganizationId = try await signUpPasskey(
      token: token, attestation: registration.apiAttestation(loginKey: loginKey), resuming: resuming
    )

    var sessionOpened = false
    if let subOrganizationId {
      sessionOpened = try await loginWithSignupKey(loginKey, organizationId: subOrganizationId)
    }
    if !sessionOpened {
      let previousKey = context.selectedStoredSessionKey
      preparePasskeyDefaultKey()
      do {
        try await context.loginWithTurnkeyPasskey(anchor: anchor, organizationId: subOrganizationId)
      } catch {
        throw RainError.from(underlying: error)
      }
      try await activatePasskeySession(previousKey: previousKey)
    }
    do {
      try await ensureWallets()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// False when the key login failed: nothing was stored, so the caller falls back to a passkey
  /// login. Only cancellation propagates.
  private func loginWithSignupKey(_ key: TemporaryApiKey, organizationId: String) async throws -> Bool {
    let attemptKey = Self.newAttemptSessionKey()
    let previousKey = context.selectedStoredSessionKey
    do {
      try await context.loginWithTemporaryKey(organizationId: organizationId, key: key, sessionKey: attemptKey)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      RainLogger.warning("Rain SDK: signup key login failed, falling back to passkey login: \(error)")
      return false
    }
    try await activateStoredSession(attemptKey: attemptKey, previousKey: previousKey)
    return true
  }

  /// `/signup/passkey` with the one-renewal token rule, sorting its endings into what the
  /// pending store must do. Nil when a resend was told the account is already saved (409):
  /// only a passkey login can open it.
  private func signUpPasskey(
    token: String,
    attestation: RainApiPasskeyAttestation,
    resuming: Bool
  ) async throws -> String? {
    do {
      let signup: RainApiSignup
      do {
        signup = try await api.signupPasskey(token: token, attestation: attestation)
      } catch let error as RainApiAuthError where error.kind == .tokenRejected || Self.isTokenUsed(error) {
        // The user has already done Face ID; giving up would leave a passkey no account knows
        // and make the next try mint a look-alike. Same one-renewal rule as the code flow. A
        // 409 "token already used" (a host that cached its token) is the same situation.
        let renewed = try await mintToken(for: nil)
        signup = try await api.signupPasskey(token: renewed, attestation: attestation)
      }
      pendingPasskeySignups.clear()
      return signup.subOrganizationId
    } catch is CancellationError {
      throw CancellationError() // outcome unknown: the registration stays
    } catch let error as RainApiAuthError {
      switch Self.passkeySignupEnding(error, resuming: resuming) {
      case .accountExists:
        pendingPasskeySignups.clear()
        return nil
      case .inProgress:
        throw RainError.providerError(underlying: TurnkeyPasskeySignupInProgress(message: error.message))
      case .refused:
        pendingPasskeySignups.clear()
        if error.kind == .conflict {
          throw RainError.invalidConfig(details:
            "This passkey already belongs to a wallet — sign in with loginWithPasskey instead: \(error.message)")
        }
        throw error.rainError
      case .unknown:
        throw error.rainError
      }
    } catch {
      // Transport failure or an unreadable answer: rain-api may still be creating the account.
      if Task.isCancelled { throw CancellationError() }
      throw RainError.from(underlying: error)
    }
  }

  private enum PasskeySignupEnding { case accountExists, inProgress, refused, unknown }

  /// 409 "This wallet auth token has already been used": nothing was created, a fresh token
  /// works. Must not read as "already has a wallet" — both messages contain "wallet".
  private static func isTokenUsed(_ error: RainApiAuthError) -> Bool {
    error.kind == .conflict && error.message.lowercased().contains("token has already been used")
  }

  /// rain-api carries no machine code, so its three 409s are told apart by message — full
  /// phrases, since two of them contain "wallet": "signup in progress" (a 120 s lock after a
  /// failed create — retry shortly, keep the registration), "already has a wallet" (on a
  /// RESEND, the earlier try worked), "token has already been used" (handled as a renewal
  /// before reaching here); anything else a refusal. 5xx and rate limits leave the outcome
  /// unknown; the rest is definitive.
  private static func passkeySignupEnding(_ error: RainApiAuthError, resuming: Bool) -> PasskeySignupEnding {
    let message = error.message.lowercased()
    switch error.kind {
    case .conflict where message.contains("in progress"):
      return .inProgress
    case .conflict where resuming && message.contains("already has a wallet"):
      return .accountExists
    case .conflict:
      return .refused
    case .serverError, .rateLimited, .other:
      return .unknown
    case .tokenRejected, .forbidden, .invalidCode, .verificationFailed, .noWallet:
      return .refused
    }
  }

  /// Registers a passkey on the CURRENT account (active session required), so the user can sign
  /// in with it later. No new account, no session change.
  internal func addPasskey(anchor: ASPresentationAnchor) async throws {
    try throwIfMisconfigured()
    try requirePasskeysConfigured()
    do {
      try await context.addPasskeyAuthenticator(anchor: anchor, rpId: rpId ?? "")
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  @discardableResult
  private func requirePasskeysConfigured() throws -> String {
    guard let rpId, !rpId.isEmpty else {
      throw RainError.invalidConfig(details:
        "Passkeys are not configured for this app: the relying-party domain is missing. "
        + "The app also needs the Associated Domains entitlement for that domain.")
    }
    return rpId
  }

  /// The vendor refuses to store a passkey session over an occupied default key — and it does so
  /// as the LAST step of the ceremony (4.0.0: createPasskey → proxySignup → stampLogin →
  /// storeSession). Over a live passkey session that would mint a keychain passkey (and, for
  /// signup, a whole Turnkey account) only to fail. We know the outcome up front, so refuse
  /// before Face ID and before any network call. `invalidConfig` is a state error here, not a
  /// configuration one, but no closer code exists and a new one would fork the cross-platform
  /// map. An EXPIRED session still parked under the selected default key protects nothing and
  /// would also block the store, so it is purged instead and the ceremony proceeds.
  private func refuseIfLivePasskeySession() async throws {
    guard context.selectedStoredSessionKey == Self.passkeyDefaultSessionKey,
          context.session != nil else { return }
    if hasActiveSession() {
      throw RainError.invalidConfig(details: "Already signed in with a passkey; log out first")
    }
    context.clearStoredSession(sessionKey: Self.passkeyDefaultSessionKey)
    // Clearing the SELECTED key flips the vendor's live state from a main-actor Task. Let it
    // settle before the ceremony so the fresh session is auto-selected, not wiped by a late flip.
    await awaitSessionTeardown()
  }

  /// The vendor refuses to store a passkey session over an occupied default key. Purge a stale
  /// stored session under it — but NEVER the live selection, so a cancelled or failed ceremony
  /// cannot log anyone out (a live passkey session is refused earlier, see
  /// `refuseIfLivePasskeySession`).
  private func preparePasskeyDefaultKey() {
    if context.selectedStoredSessionKey != Self.passkeyDefaultSessionKey {
      context.clearStoredSession(sessionKey: Self.passkeyDefaultSessionKey)
    }
  }

  private static func newAttemptSessionKey() -> String {
    "rain-turnkey-\(UUID().uuidString)"
  }

  /// The vendor auto-selects a stored session only when none was selected; over a live session
  /// the attempt key is activated explicitly, then the superseded key is purged.
  private func activateStoredSession(attemptKey: String, previousKey: String?) async throws {
    do {
      if context.selectedStoredSessionKey != attemptKey {
        try await context.selectStoredSession(sessionKey: attemptKey)
      }
    } catch {
      // Don't leave the never-selected attempt session orphaned in the keychain.
      context.clearStoredSession(sessionKey: attemptKey)
      throw RainError.from(underlying: error)
    }
    if let previousKey, previousKey != attemptKey {
      context.clearStoredSession(sessionKey: previousKey)
    }
  }

  /// Same for a passkey session, which the vendor always stores under ITS default key.
  private func activatePasskeySession(previousKey: String?) async throws {
    do {
      if context.selectedStoredSessionKey != Self.passkeyDefaultSessionKey {
        try await context.selectStoredSession(sessionKey: Self.passkeyDefaultSessionKey)
      }
    } catch {
      // Don't leave the never-selected passkey session orphaned in the keychain.
      context.clearStoredSession(sessionKey: Self.passkeyDefaultSessionKey)
      throw RainError.from(underlying: error)
    }
    if let previousKey, previousKey != Self.passkeyDefaultSessionKey {
      context.clearStoredSession(sessionKey: previousKey)
    }
  }

  // MARK: Contact verification (attach a login contact to the current account)

  /// Sends a verification code to a contact the user wants to ATTACH to the current account
  /// (active session required). Distinct from `sendLoginCode`, which starts a login. Rides on
  /// a wallet auth token minted for the NEW contact.
  internal func sendContactVerificationCode(to contact: TurnkeyLoginContact) async throws {
    try throwIfMisconfigured()
    guard hasActiveSession() else { throw RainError.tokenExpired }
    // Normalized before it is verified and attached — the stored contact must be the exact
    // string a later login normalizes to.
    let contact = try contact.normalized()
    let token = try await mintToken(for: contact)
    do {
      let challenge = try await api.initOtp(token: token)
      pendingOtpLock.withLock {
        pendingContactVerification = PendingCode(token: token, challenge: challenge, contact: contact)
      }
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// Confirms the code from `sendContactVerificationCode` and attaches the contact — VERIFIED,
  /// so it becomes a login method for this account. The verification token rain-api returns is
  /// the same Turnkey token the vendor's `updateUserEmail` / `updateUserPhoneNumber` accept. A
  /// wrong code throws `invalidLoginCode` and keeps the challenge, so the user can retype it.
  ///
  /// Refused with `unauthorized` (RAIN_202) when the contact is already the login of ANOTHER
  /// wallet in this tenant: attaching it would leave rain-api with two wallets for one contact,
  /// after which every code login for it fails (500), and the vendor's update REPLACES this
  /// account's existing contact, so both wallets could end up with no code login at all.
  /// Re-attaching a contact this account already owns is allowed. The challenge is dropped
  /// either way; the user has to start over.
  internal func confirmContactVerification(_ code: String) async throws {
    try throwIfMisconfigured()
    guard var pending = pendingOtpLock.withLock({ pendingContactVerification }) else {
      throw RainError.invalidConfig(details:
        "No verification code was requested; call sendContactVerificationCode first")
    }
    do {
      let publicKey = try context.createOtpKeyPair()
      let encrypted = try context.encryptOtpCode(
        code,
        otpEncryptionTargetBundle: pending.challenge.otpEncryptionTargetBundle,
        publicKey: publicKey
      )
      let otpId = pending.challenge.otpId
      let verification = try await withTokenRetry(&pending) { token in
        try await api.verifyOtp(token: token, otpId: otpId, encryptedOtpBundle: encrypted)
      }
      if let owner = verification.walletSubOrganizationId, owner != context.session?.organizationId {
        pendingOtpLock.withLock { pendingContactVerification = nil }
        throw RainError.unauthorized(details:
          "This contact is already the login for another wallet; sign in to that wallet instead")
      }
      switch pending.contact {
      case .email(let email):
        try await context.setUserEmail(email, verificationToken: verification.verificationToken)
      case .phone(let phone):
        try await context.setUserPhoneNumber(phone, verificationToken: verification.verificationToken)
      }
      pendingOtpLock.withLock { pendingContactVerification = nil }
    } catch let error as RainApiAuthError where error.kind == .invalidCode {
      pendingOtpLock.withLock { pendingContactVerification = pending }
      throw RainError.invalidLoginCode
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  internal func logout() async {
    context.clearStoredSession(sessionKey: nil) // nil = the currently selected session
    pendingOtpLock.withLock {
      pendingOtp = nil
      pendingContactVerification = nil
    }
    // The vendor wipes storage synchronously but flips `session` / `authState` from a main-actor
    // Task slightly later. Wait (bounded) for the live state to settle so callers can read
    // `authState` / `hasActiveSession()` immediately after logout returns.
    await awaitSessionTeardown()
  }

  /// Bounded wait for the vendor's asynchronous live-state flip after the selected session was
  /// cleared.
  private func awaitSessionTeardown() async {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if context.session == nil && context.authState == .unAuthenticated { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  // MARK: Wallet provisioning

  /// Ensures the authenticated account has an Ethereum (secp256k1) and a Solana (ed25519)
  /// account, on ONE wallet seed. Fresh signups already get both atomically (see
  /// `signupWalletAccounts` on `completeOtp`); this backfills accounts that predate that, by
  /// deriving the missing account(s) from the existing wallet's seed — never by creating a
  /// second wallet. Idempotent: existing accounts are kept.
  private func ensureWallets() async throws {
    try await context.refreshWallets()
    guard let wallet = context.wallets.first else {
      // No wallet at all (an account created outside this flow): one wallet, both accounts.
      try await context.createTurnkeyWallet(
        walletName: "Wallet",
        accounts: [Self.ethereumAccount, Self.solanaAccount],
        mnemonicLength: 12
      )
      return
    }
    let formats = Set(context.wallets.flatMap(\.accounts).map(\.addressFormat))
    var missing: [WalletAccountParams] = []
    if !formats.contains(.address_format_ethereum) { missing.append(Self.ethereumAccount) }
    if !formats.contains(.address_format_solana) { missing.append(Self.solanaAccount) }
    guard !missing.isEmpty else { return }
    try await context.addAccountsToTurnkeyWallet(walletId: wallet.walletId, accounts: missing)
  }

  // MARK: Key export

  /// Exports the wallet's 12-word mnemonic phrase, decrypted on-device. One wallet seed per
  /// account (see `ensureWallets`), so a single phrase restores every chain family.
  /// The SDK never logs or persists the value; display and gating are the host's responsibility.
  internal func exportMnemonic() async throws -> String {
    try throwIfMisconfigured()
    do {
      let wallet = try await requireWallet()
      return try await context.exportWalletMnemonic(walletId: wallet.walletId)
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// Exports one account's private key, decrypted on-device: Ethereum as a 0x-prefixed 32-byte
  /// hex string (the form Ethereum wallets import), Solana as plain Base58 of privkey‖pubkey —
  /// formats shared with the Android SDK.
  /// The SDK never logs or persists the value; display and gating are the host's responsibility.
  internal func exportPrivateKey(family: TurnkeyKeyFamily) async throws -> String {
    try throwIfMisconfigured()
    do {
      _ = try await requireWallet()
      let format: v1AddressFormat =
        family == .ethereum ? .address_format_ethereum : .address_format_solana
      guard let account = context.wallets.flatMap(\.accounts).first(where: { $0.addressFormat == format })
      else {
        // Login provisions both families (ensureWallets); reaching this means provisioning was
        // interrupted — a re-login repairs it.
        throw RainError.internalError(
          details: "No \(family) account exists to export; log in again to provision it")
      }
      let value = try await context.exportAccountPrivateKey(
        address: account.address,
        encoding: family == .ethereum ? .hexSecp256k1 : .solanaBase58
      )
      // The decrypted secp256k1 key is bare hex; the 0x prefix is the Rain-boundary format.
      return family == .ethereum ? "0x" + value : value
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// The account's wallet, refreshing the cached list once if it is empty. Post one-seed
  /// provisioning there is exactly one; legacy accounts can still hold several wallets (several
  /// seeds), so anchor on the wallet carrying the Ethereum account in use — the exported phrase
  /// must derive the same address as the exported Ethereum key.
  private func requireWallet() async throws -> Wallet {
    if context.wallets.isEmpty {
      try await context.refreshWallets()
    }
    let wallets = context.wallets
    let ethereumWallet = wallets.first { wallet in
      wallet.accounts.contains { $0.addressFormat == .address_format_ethereum }
    }
    guard let wallet = ethereumWallet ?? wallets.first else {
      throw TurnkeySwiftError.invalidSession
    }
    return wallet
  }

  private func throwIfMisconfigured() throws {
    if let configurationError { throw configurationError }
  }
}
