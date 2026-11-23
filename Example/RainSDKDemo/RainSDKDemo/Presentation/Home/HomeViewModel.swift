import AuthenticationServices
import Combine
import Foundation
import RainCore
import RainWallet
import UIKit
import UniformTypeIdentifiers

/// Wallet provider the demo initializes with.
enum WalletMode: String, CaseIterable, Identifiable {
  case rainWallet = "Rain Wallet"
  case turnkey = "Turnkey"
  case portal = "Portal MPC"
  case privy = "Privy"

  var id: String { rawValue }
}

/// Drives the home screen: provider selection, credentials, auth, and SDK initialization.
@MainActor
final class HomeViewModel: ObservableObject {
  private let session: RainSDKService

  @Published var mode: WalletMode = .rainWallet

  // Rain API credentials — independent of the wallet provider.
  @Published var rainApiKey = "" { didSet { pushRainApiCredentials() } }
  @Published var userId = "" { didSet { pushRainApiCredentials() } }

  // Portal
  @Published var sessionToken = ""
  /// Portal only: installed by "Update token" or handed to `onSessionTokenNeeded`.
  @Published var replacementPortalToken = ""

  // Turnkey
  @Published var turnkeyOrgId = ""
  @Published var turnkeyAuthProxyConfigId = ""
  @Published var turnkeyEmail = ""
  @Published var turnkeyOtpCode = ""
  @Published private(set) var turnkeyOtpId: String?
  @Published private(set) var turnkeySessionActive = false
  private var turnkeyOtpEncryptionBundle: String?

  /// Delivery channel for the Rain wallet login code.
  enum RainWalletContactKind: String, CaseIterable, Identifiable {
    case email = "Email"
    case phone = "Phone (SMS)"
    var id: String { rawValue }
  }

  // Rain Wallet — backend identity is embedded in the SDK; only the contact is needed.
  @Published var rainWalletContactKind: RainWalletContactKind = .email
  @Published var rainWalletEmail = ""
  @Published var rainWalletPhone = ""
  @Published var rainWalletOtpCode = ""
  @Published private(set) var rainWalletOtpSent = false
  @Published private(set) var rainWalletSessionActive = false

  // Privy
  @Published var privyAppId = ""
  @Published var privyAppClientId = ""
  @Published var privyEmail = ""
  @Published var privyOtpCode = ""
  @Published private(set) var privyOtpSent = false
  @Published private(set) var privySessionActive = false

  @Published private(set) var isInitialized = false
  /// True once the wallet is ready to use — the feature grid appears.
  @Published private(set) var isRecovered = false
  @Published private(set) var isLoading = false
  @Published private(set) var statusText = "Ready"

  private var cancellables = Set<AnyCancellable>()

  init() {
    self.session = .shared
    mode = SessionStore.provider.map(WalletMode.init) ?? .rainWallet
    seedFields()
    // didSet does not fire inside init, so push explicitly.
    pushRainApiCredentials()

    // Portal Refreshing→Active means onSessionTokenNeeded consumed the replacement.
    session.$sessionStatus
      .scan((previous: WalletSessionStatus?.none, current: WalletSessionStatus?.none)) { ($0.current, $1) }
      .sink { [weak self] transition in
        guard let self, mode == .portal,
              transition.previous?.health == .transitional,
              transition.current?.health == .healthy,
              !replacementPortalToken.trimmed.isEmpty else { return }
        sessionToken = replacementPortalToken.trimmed
        SessionStore.portalSessionToken = sessionToken
        replacementPortalToken = ""
      }
      .store(in: &cancellables)

    if session.isInitialized { markResumed() } else { Task { await resumeIfPossible() } }
  }

  // MARK: - Resume

  /// The SDK outlived this view model: reflect its state without re-initializing.
  private func markResumed() {
    isInitialized = true
    isRecovered = true
    turnkeySessionActive = mode == .turnkey
    privySessionActive = mode == .privy
    rainWalletSessionActive = mode == .rainWallet
    statusText = "Session resumed"
  }

  /// Replays the saved provider through the same paths the buttons use; falls back to the manual screen.
  private func resumeIfPossible() async {
    guard let provider = SessionStore.provider else { return }
    isLoading = true
    statusText = "Resuming \(provider.rawValue.capitalized) session..."
    switch provider {
    case .portal:
      isLoading = false
      if sessionToken.trimmed.isEmpty { statusText = "Ready" } else { await initializeSdk() }
    case .turnkey:
      await TurnkeyAuthSample.awaitSessionRestore()
      guard TurnkeyAuthSample.hasActiveSession() else {
        return resumeFallback("Saved Turnkey session expired — log in again")
      }
      guard await TurnkeyAuthSample.activeSessionEmail().matches(turnkeyEmail) else {
        return resumeFallback("Saved Turnkey session belongs to another email — log in again")
      }
      turnkeySessionActive = true
      isLoading = false
      await initializeRainWithTurnkey()
    case .rainWallet:
      let rainWalletProvider = session.prepareRainWallet(onSessionExpired: rainWalletExpiryHandler)
      await rainWalletProvider.awaitSessionRestore()
      guard rainWalletProvider.hasActiveSession() else {
        return resumeFallback("Saved Rain Wallet session expired — log in again")
      }
      rainWalletSessionActive = true
      isLoading = false
      await initializeRainWithRainWallet()
    case .privy:
      guard await PrivyAuthSample.shared.hasActiveSession() else {
        return resumeFallback("Saved Privy session expired — log in again")
      }
      guard await PrivyAuthSample.shared.activeSessionEmail().matches(privyEmail) else {
        return resumeFallback("Saved Privy session belongs to another email — log in again")
      }
      privySessionActive = true
      isLoading = false
      await initializeRainWithPrivy()
    }
  }

  /// Fields start from the last working values; empty on first run.
  private func seedFields() {
    rainApiKey = SessionStore.rainApiKey
    userId = SessionStore.rainUserId
    sessionToken = SessionStore.portalSessionToken
    turnkeyOrgId = SessionStore.turnkeyOrgId
    turnkeyAuthProxyConfigId = SessionStore.turnkeyAuthProxyConfigId
    turnkeyEmail = SessionStore.turnkeyEmail
    let rainWalletContact = SessionStore.rainWalletContact
    if rainWalletContact.contains("@") || rainWalletContact.isEmpty {
      rainWalletEmail = rainWalletContact
    } else {
      rainWalletPhone = rainWalletContact
      rainWalletContactKind = .phone
    }
    privyAppId = SessionStore.privyAppId
    privyAppClientId = SessionStore.privyAppClientId
    privyEmail = SessionStore.privyEmail
  }

  private func resumeFallback(_ message: String) {
    SampleLog.i("Resume", message)
    isLoading = false
    statusText = message
  }

  private func persistRainCredentials(_ provider: SessionStore.Provider) {
    SessionStore.provider = provider
    SessionStore.rainApiKey = rainApiKey.trimmed
    SessionStore.rainUserId = userId.trimmed
  }

  var selectedChain: WalletChain {
    get { session.selectedChain }
    set { session.selectedChain = newValue }
  }

  /// Portal holds no Solana account, so it only ever operates on the EVM chains.
  var availableChains: [WalletChain] {
    WalletChain.selectable.filter { mode != .portal || !$0.isSolana }
  }

  func onModeChanged(_ mode: WalletMode) {
    guard !isInitialized else { return }
    SampleLog.d("Home", "mode changed: \(mode.rawValue)")
    self.mode = mode
  }

  private func pushRainApiCredentials() {
    session.configureRainApi(apiKey: rainApiKey, userId: userId)
  }

  // MARK: - Portal

  var canInitializePortal: Bool {
    !sessionToken.trimmed.isEmpty && !isInitialized && !isLoading
  }

  func initializeSdk() async {
    guard canInitializePortal else { return }
    let token = sessionToken.trimmed
    SampleLog.i("Portal.init", "calling initializePortal sessionToken=\(SampleLog.maskToken(token))")
    isLoading = true
    statusText = "Initializing Portal..."

    do {
      try await session.initializePortal(
        sessionToken: token,
        // A host mints a new token for the SAME Portal client here; this demo has no backend,
        // so it returns the typed replacement (read on the main actor) or nil (declines).
        onSessionTokenNeeded: { [weak self] in
          let replacement = await MainActor.run { self?.replacementPortalToken.trimmed ?? "" }
          guard !replacement.isEmpty else {
            SampleLog.w("Portal.session", "onSessionTokenNeeded: no replacement token, declining")
            return nil
          }
          SampleLog.i("Portal.session", "onSessionTokenNeeded: supplying replacement token")
          return replacement
        },
        // Recovery is "Update token" or Clear Session; the feature grid hides meanwhile.
        onSessionExpired: { [weak self] in
          SampleLog.w("Portal.session", "Portal session token rejected, new token required")
          Task { @MainActor [weak self] in
            self?.statusText = "Portal session expired — enter a replacement token"
          }
        }
      )

      // A freshly-created Portal client has no wallet; generate one before any screen asks
      // for an address. MPC keygen takes a few seconds on first run.
      statusText = "Setting up wallet..."
      let createdWallet = try await session.ensurePortalWallet()

      SampleLog.i(
        "Portal.init",
        "success — isInitialized=\(session.isInitialized) createdWallet=\(createdWallet)"
      )
      // Recovery (the Portal backup share) is no longer available via the Rain API, so a
      // successful init goes straight to the feature grid instead of gating on recovery.
      persistRainCredentials(.portal)
      SessionStore.portalSessionToken = token
      isInitialized = session.isInitialized
      isRecovered = true
      statusText = "SDK Initialized Successfully!"
    } catch {
      SampleLog.e("Portal.init", "failed: \(error.localizedDescription)")
      isInitialized = false
      statusText = "Error: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Session

  var canUpdatePortalToken: Bool {
    !replacementPortalToken.trimmed.isEmpty && !isLoading
  }

  func refreshSession() async {
    SampleLog.i("Session", "manual refreshSession() on \(mode.rawValue)")
    isLoading = true
    statusText = "Refreshing session..."
    do {
      try await session.refreshSession()
      statusText = "Session refreshed"
    } catch {
      SampleLog.e("Session", "refresh failed: \(error.localizedDescription)")
      statusText = "Session refresh failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  /// Portal only: installs the replacement token in place — no SDK rebuild.
  func updatePortalSessionToken() async {
    let token = replacementPortalToken.trimmed
    guard !token.isEmpty else { return }
    SampleLog.i("Portal.session", "updateSessionToken(\(SampleLog.maskToken(token)))")
    isLoading = true
    statusText = "Installing new Portal session token..."
    do {
      try await session.updatePortalSessionToken(token)
      SessionStore.portalSessionToken = token
      sessionToken = token
      replacementPortalToken = ""
      statusText = "Portal session token updated"
    } catch {
      SampleLog.e("Portal.session", "updateSessionToken failed: \(error.localizedDescription)")
      statusText = "Token update failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Turnkey

  var canSendTurnkeyOtp: Bool {
    !turnkeyOrgId.trimmed.isEmpty
      && !turnkeyAuthProxyConfigId.trimmed.isEmpty
      && !turnkeyEmail.trimmed.isEmpty
      && !isLoading
      && turnkeyOtpId == nil
  }

  var canVerifyTurnkeyOtp: Bool {
    !turnkeyOtpCode.trimmed.isEmpty && !isLoading && !turnkeySessionActive
  }

  func sendTurnkeyOtp() async {
    guard canSendTurnkeyOtp else {
      statusText = "Org ID, Auth Proxy Config ID, and Email are required"
      return
    }
    let email = turnkeyEmail.trimmed
    SampleLog.i("Turnkey.otpInit", "starting email-OTP flow email=\(SampleLog.maskEmail(email))")
    // Saved before configure so a relaunch (the only way to change ids) picks up the new values.
    SessionStore.provider = .turnkey
    SessionStore.turnkeyOrgId = turnkeyOrgId.trimmed
    SessionStore.turnkeyAuthProxyConfigId = turnkeyAuthProxyConfigId.trimmed
    SessionStore.turnkeyEmail = email
    isLoading = true
    statusText = "Initializing Turnkey..."

    do {
      try TurnkeyAuthSample.configure(
        organizationId: turnkeyOrgId.trimmed,
        authProxyConfigId: turnkeyAuthProxyConfigId.trimmed
      )

      // Turnkey restores a valid session from the Keychain. Only reuse it when it provably
      // belongs to the email being logged in — otherwise entering a different email would
      // silently continue as the previous user. On mismatch, log out and run the full OTP flow.
      if TurnkeyAuthSample.hasActiveSession() {
        let sessionEmail = await TurnkeyAuthSample.activeSessionEmail()
        if let sessionEmail, sessionEmail.caseInsensitiveCompare(email) == .orderedSame {
          SampleLog.i("Turnkey.otpInit", "existing session restored for this email — skipping OTP")
          turnkeySessionActive = true
          statusText = "Existing Turnkey session restored — initialize Rain to continue"
          isLoading = false
          return
        }
        SampleLog.w(
          "Turnkey.otpInit",
          "restored session belongs to \(SampleLog.maskEmail(sessionEmail)), "
          + "not \(SampleLog.maskEmail(email)) — logging out"
        )
        TurnkeyAuthSample.logout()
      }

      statusText = "Sending OTP to \(email)..."
      let result = try await TurnkeyAuthSample.sendEmailOtp(email: email)
      turnkeyOtpId = result.otpId
      turnkeyOtpEncryptionBundle = result.otpEncryptionTargetBundle
      statusText = "OTP sent — check your email"
      SampleLog.i("Turnkey.otpInit", "OTP sent")
    } catch {
      SampleLog.e("Turnkey.otpInit", "failed: \(error.localizedDescription)")
      statusText = "Turnkey OTP init failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  func verifyTurnkeyOtp() async {
    guard let otpId = turnkeyOtpId, let bundle = turnkeyOtpEncryptionBundle else {
      statusText = "Send OTP first"
      return
    }
    guard canVerifyTurnkeyOtp else {
      statusText = "OTP code required"
      return
    }

    SampleLog.i("Turnkey.otpVerify", "verifying OTP")
    isLoading = true
    statusText = "Verifying OTP..."

    do {
      try await TurnkeyAuthSample.verifyEmailOtp(
        otpId: otpId,
        otpCode: turnkeyOtpCode.trimmed,
        otpEncryptionTargetBundle: bundle,
        email: turnkeyEmail.trimmed
      )
      turnkeySessionActive = true
      statusText = "Turnkey session active — initialize Rain to continue"
    } catch {
      SampleLog.e("Turnkey.otpVerify", "failed: \(error.localizedDescription)")
      statusText = "OTP verification failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  func initializeRainWithTurnkey() async {
    guard turnkeySessionActive else {
      statusText = "Verify OTP first"
      return
    }
    SampleLog.i("Turnkey.rainInit", "initializing Rain w/ Turnkey (EVM + Solana)")
    isLoading = true
    statusText = "Initializing Rain with Turnkey..."

    do {
      // One wallet carrying both the Ethereum and Solana accounts (a single seed to back up).
      if try await TurnkeyAuthSample.ensureWallets() {
        statusText = "Provisioned Turnkey wallet, initializing Rain..."
      }

      try await session.initializeTurnkey(
        turnkey: TurnkeyAuthSample.context,
        // Restart the OTP flow; a fresh login revives the provider (it watches the process-wide
        // Turnkey singleton), so Rain is not re-initialized.
        onSessionExpired: { [weak self] in
          SampleLog.w("Turnkey.session", "Turnkey session expired, re-auth required")
          Task { @MainActor [weak self] in
            guard let self else { return }
            turnkeySessionActive = false
            turnkeyOtpId = nil
            turnkeyOtpEncryptionBundle = nil
            turnkeyOtpCode = ""
            statusText = "Turnkey session expired — log in again"
          }
        }
      )
      await logResolvedAddresses(area: "Turnkey.rainInit")
      persistRainCredentials(.turnkey)
      isInitialized = session.isInitialized
      isRecovered = true
      statusText = "Rain initialized with Turnkey — wallet ready"
    } catch {
      SampleLog.e("Turnkey.rainInit", "failed: \(error.localizedDescription)")
      statusText = "Rain Turnkey init failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Rain Wallet

  var rainWalletUsePhone: Bool { rainWalletContactKind == .phone }

  /// The login contact from the current inputs, or nil while it is empty.
  var rainWalletContact: RainWalletContact? {
    if rainWalletUsePhone {
      let phone = rainWalletPhone.trimmed
      return phone.isEmpty ? nil : .phone(phone)
    }
    let email = rainWalletEmail.trimmed
    return email.isEmpty ? nil : .email(email)
  }

  /// The demo mints wallet auth tokens with the Rain API key itself (a real app's backend does),
  /// so the code flows need it; passkey login does not. The user id is only for the user-scoped
  /// calls behind Withdraw and Auth pull.
  var hasRainApiKey: Bool { !rainApiKey.trimmed.isEmpty }

  var canSendRainWalletOtp: Bool {
    hasRainApiKey && rainWalletContact != nil && !isLoading && !rainWalletOtpSent
  }

  var canVerifyRainWalletOtp: Bool {
    !rainWalletOtpCode.trimmed.isEmpty && !isLoading && !rainWalletSessionActive && rainWalletSecondCodeContact == nil
  }

  /// Set once the first code verified for an account Rain protects with two codes: the masked
  /// contact the second code goes to. Nil outside that step.
  @Published private(set) var rainWalletSecondCodeContact: String?
  @Published var rainWalletSecondCode = ""

  var canVerifyRainWalletSecondCode: Bool {
    rainWalletSecondCodeContact != nil && !rainWalletSecondCode.trimmed.isEmpty && !isLoading
  }

  private func resetRainWalletCodeSteps() {
    rainWalletOtpSent = false
    rainWalletOtpCode = ""
    rainWalletSecondCodeContact = nil
    rainWalletSecondCode = ""
  }

  /// Expiry hook shared by the send and resume paths: restart the login-code flow.
  private var rainWalletExpiryHandler: @Sendable () -> Void {
    { [weak self] in
      SampleLog.w("RainWallet.session", "Rain Wallet session expired, re-auth required")
      Task { @MainActor [weak self] in
        guard let self else { return }
        // The SDK's watcher reports a logout as a session death too; an intentional Clear
        // session must not read as an expiry.
        guard !isClearingSession else { return }
        rainWalletSessionActive = false
        resetRainWalletCodeSteps()
        revealedSecret = nil
        statusText = "Rain Wallet session expired — log in again"
      }
    }
  }

  func sendRainWalletOtp() async {
    guard hasRainApiKey else {
      statusText = "Enter the Rain API key first — the demo mints wallet auth tokens with it"
      return
    }
    guard canSendRainWalletOtp, let contact = rainWalletContact else {
      statusText = rainWalletUsePhone ? "Phone number is required" : "Email is required"
      return
    }
    let contactValue: String
    switch contact {
    case .email(let email): contactValue = email
    case .phone(let phone): contactValue = phone
    }
    let previousContact = SessionStore.rainWalletContact
    SampleLog.i("RainWallet.otpInit", "starting login-code flow (\(rainWalletUsePhone ? "sms" : "email"))")
    SessionStore.provider = .rainWallet
    SessionStore.rainWalletContact = contactValue
    isLoading = true
    statusText = "Initializing Rain Wallet..."

    do {
      let provider = session.prepareRainWallet(onSessionExpired: rainWalletExpiryHandler)
      await provider.awaitSessionRestore()

      if provider.hasActiveSession() {
        if previousContact.caseInsensitiveCompare(contactValue) == .orderedSame {
          SampleLog.i("RainWallet.otpInit", "existing session restored for this contact — skipping OTP")
          rainWalletSessionActive = true
          statusText = "Existing session restored — initialize Rain to continue"
          isLoading = false
          return
        }
        SampleLog.w("RainWallet.otpInit", "restored session belongs to a different contact — logging out")
        try await provider.logout()
      }

      statusText = "Sending login code..."
      try await provider.sendLoginCode(to: contact)
      rainWalletOtpSent = true
      statusText = rainWalletUsePhone
        ? "Login code sent — check your messages" : "Login code sent — check your email"
    } catch {
      SampleLog.e("RainWallet.otpInit", "failed: \(error.localizedDescription)")
      statusText = "Rain Wallet login init failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Rain Wallet passkeys

  /// Signs in with an existing passkey, then initializes Rain — the passkey twin of the
  /// verify-code path.
  func signInWithRainWalletPasskey() async {
    await runRainWalletPasskey(area: "RainWallet.passkeyLogin", label: "Signing in with passkey") { provider, anchor in
      try await provider.loginWithPasskey(anchor: anchor)
    }
  }

  /// Creates a brand-new account with a passkey. Every call mints a fresh account — returning
  /// users must use sign-in.
  func signUpWithRainWalletPasskey() async {
    await runRainWalletPasskey(area: "RainWallet.passkeySignup", label: "Creating wallet with passkey") { provider, anchor in
      try await provider.signUpWithPasskey(anchor: anchor)
    }
  }

  /// Adds a passkey to the current account so the next login can skip the code.
  func addRainWalletPasskey() async {
    guard rainWalletSessionActive, let provider = session.rainWalletProvider else {
      statusText = "Log in with Rain Wallet first"
      return
    }
    SampleLog.i("RainWallet.passkeyAdd", "registering a passkey on the current account")
    isLoading = true
    do {
      try await provider.addPasskey(anchor: presentationAnchor())
      statusText = "Passkey added — next login can use it"
    } catch {
      SampleLog.e("RainWallet.passkeyAdd", "failed: \(error.localizedDescription)")
      statusText = "Adding the passkey failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Rain Wallet contact attach

  /// A passkey-only account has no login contact; attaching one (verified) gives it a second
  /// login method. Uses the same email/phone inputs as sign-in — on a live session those fields
  /// mean "contact to attach".
  @Published var rainWalletAttachCodeSent = false
  @Published var rainWalletAttachCode = ""

  var canSendRainWalletAttachCode: Bool {
    hasRainApiKey && rainWalletSessionActive && rainWalletContact != nil && !isLoading && !rainWalletAttachCodeSent
  }

  var canConfirmRainWalletAttach: Bool {
    rainWalletAttachCodeSent && !rainWalletAttachCode.trimmed.isEmpty && !isLoading
  }

  func sendRainWalletAttachCode() async {
    guard rainWalletSessionActive, let provider = session.rainWalletProvider else {
      statusText = "Log in with Rain Wallet first"
      return
    }
    guard let contact = rainWalletContact else {
      statusText = rainWalletUsePhone ? "Phone number is required" : "Email is required"
      return
    }
    SampleLog.i("RainWallet.attach", "sending verification code (\(rainWalletUsePhone ? "sms" : "email"))")
    isLoading = true
    do {
      try await provider.sendContactVerificationCode(to: contact)
      rainWalletAttachCodeSent = true
      statusText = "Verification code sent — enter it to attach the contact"
    } catch {
      SampleLog.e("RainWallet.attach", "send failed: \(error.localizedDescription)")
      statusText = "Sending the verification code failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  func confirmRainWalletAttach() async {
    guard rainWalletSessionActive, let provider = session.rainWalletProvider else {
      statusText = "Log in with Rain Wallet first"
      return
    }
    SampleLog.i("RainWallet.attach", "confirming verification code")
    isLoading = true
    do {
      try await provider.confirmContactVerification(rainWalletAttachCode.trimmed)
      rainWalletAttachCodeSent = false
      rainWalletAttachCode = ""
      statusText = "Contact attached — it can now be used to log in"
    } catch {
      SampleLog.e("RainWallet.attach", "confirm failed: \(error.localizedDescription)")
      // A wrong code keeps the challenge alive; the user can retype it.
      statusText = "Attaching the contact failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  /// Shared shell of the two passkey auth entry points: prepare the provider, run the ceremony,
  /// then flow into the standard Rain initialization.
  private func runRainWalletPasskey(
    area: String,
    label: String,
    _ ceremony: (RainWallet.RainProvider, ASPresentationAnchor) async throws -> Void
  ) async {
    SampleLog.i(area, "starting passkey ceremony")
    SessionStore.provider = .rainWallet
    isLoading = true
    statusText = "\(label)..."
    do {
      let provider = session.prepareRainWallet(onSessionExpired: rainWalletExpiryHandler)
      await provider.awaitSessionRestore()
      try await ceremony(provider, presentationAnchor())
      rainWalletSessionActive = true
      isLoading = false
      await initializeRainWithRainWallet()
      return
    } catch {
      SampleLog.e(area, "failed: \(error.localizedDescription)")
      statusText = "\(label) failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  /// The key window, for the system passkey sheet.
  private func presentationAnchor() -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }

  func verifyRainWalletOtp() async {
    guard rainWalletOtpSent, let provider = session.rainWalletProvider else {
      statusText = "Send the login code first"
      return
    }
    guard canVerifyRainWalletOtp else {
      statusText = "Login code required"
      return
    }

    SampleLog.i("RainWallet.otpVerify", "verifying login code")
    isLoading = true
    statusText = "Verifying login code..."

    do {
      switch try await provider.confirmLoginCode(rainWalletOtpCode.trimmed) {
      case .signedIn:
        await rainWalletSignedIn()
        return
      case .secondCodeRequired(let contact):
        SampleLog.i("RainWallet.otpVerify", "account needs a second code (\(contact.kind))")
        rainWalletSecondCodeContact = contact.masked
        isLoading = false
        await sendRainWalletSecondCode()
        return
      }
    } catch {
      SampleLog.e("RainWallet.otpVerify", "failed: \(error.localizedDescription)")
      statusText = "Login code verification failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  /// Has Rain send (or resend) the second code to the account's other contact.
  func sendRainWalletSecondCode() async {
    guard let masked = rainWalletSecondCodeContact, let provider = session.rainWalletProvider else { return }
    isLoading = true
    statusText = "Sending second code..."
    do {
      try await provider.sendSecondLoginCode()
      statusText = "Second code sent to \(masked)"
    } catch {
      SampleLog.e("RainWallet.secondCode", "send failed: \(error.localizedDescription)")
      if case RainError.networkError = error {
        statusText = "Sending the second code failed — try again: \(error.localizedDescription)"
      } else {
        // Every other refusal ended the attempt on the SDK's side.
        resetRainWalletCodeSteps()
        statusText = "Second code failed — request a new login code: \(error.localizedDescription)"
      }
    }
    isLoading = false
  }

  func verifyRainWalletSecondCode() async {
    guard canVerifyRainWalletSecondCode, let provider = session.rainWalletProvider else { return }
    isLoading = true
    statusText = "Verifying second code..."
    do {
      try await provider.confirmSecondLoginCode(rainWalletSecondCode.trimmed)
      await rainWalletSignedIn()
      return
    } catch RainError.invalidLoginCode {
      statusText = "Wrong second code — try again"
    } catch {
      SampleLog.e("RainWallet.secondCode", "verify failed: \(error.localizedDescription)")
      resetRainWalletCodeSteps()
      statusText = "Second code failed — request a new login code: \(error.localizedDescription)"
    }
    isLoading = false
  }

  /// No manual init step: go straight into Rain. On failure the status explains and the
  /// "Initialize Rain with Rain Wallet" button stays as the retry.
  private func rainWalletSignedIn() async {
    rainWalletSessionActive = true
    rainWalletSecondCodeContact = nil
    rainWalletSecondCode = ""
    isLoading = false
    await initializeRainWithRainWallet()
  }

  func initializeRainWithRainWallet() async {
    guard rainWalletSessionActive else {
      statusText = "Verify the login code first"
      return
    }
    SampleLog.i("RainWallet.rainInit", "initializing Rain w/ Rain Wallet (EVM + Solana)")
    isLoading = true
    statusText = "Initializing Rain with Rain Wallet..."

    do {
      try await session.initializeRainWallet()
      await logResolvedAddresses(area: "RainWallet.rainInit")
      persistRainCredentials(.rainWallet)
      isInitialized = session.isInitialized
      isRecovered = true
      statusText = "Rain initialized with Rain Wallet — wallet ready"
    } catch {
      SampleLog.e("RainWallet.rainInit", "failed: \(error.localizedDescription)")
      statusText = "Rain Wallet init failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Rain Wallet key export

  enum RainWalletExportKind: String {
    case recoveryPhrase = "Recovery phrase"
    case ethereumKey = "Ethereum private key"
    case solanaKey = "Solana private key"
  }

  struct RevealedSecret: Equatable {
    let title: String
    let value: String
  }

  /// The one currently revealed secret (tap-to-reveal, hidden again on demand or logout).
  /// The value is displayed only — never logged, persisted, or put on the pasteboard.
  @Published private(set) var revealedSecret: RevealedSecret?

  func exportRainWalletSecret(_ kind: RainWalletExportKind) async {
    guard rainWalletSessionActive, let provider = session.rainWalletProvider else {
      statusText = "Log in with Rain Wallet first"
      return
    }
    SampleLog.i("RainWallet.export", "exporting \(kind.rawValue)") // the kind only, never the value
    isLoading = true
    do {
      let value: String
      switch kind {
      case .recoveryPhrase: value = try await provider.exportRecoveryPhrase()
      case .ethereumKey: value = try await provider.exportPrivateKey(.ethereum)
      case .solanaKey: value = try await provider.exportPrivateKey(.solana)
      }
      revealedSecret = RevealedSecret(title: kind.rawValue, value: value)
      statusText = "\(kind.rawValue) revealed — hide it when you're done"
    } catch {
      SampleLog.e("RainWallet.export", "failed: \(error.localizedDescription)")
      statusText = "Export failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  func hideRevealedSecret() {
    revealedSecret = nil
  }

  /// Puts the revealed secret on the pasteboard, local-only (no Handoff/universal clipboard)
  /// and self-expiring after 60 seconds.
  func copyRevealedSecret() {
    guard let secret = revealedSecret else { return }
    UIPasteboard.general.setItems(
      [[UTType.utf8PlainText.identifier: secret.value]],
      options: [
        .localOnly: true,
        .expirationDate: Date().addingTimeInterval(60),
      ]
    )
    statusText = "\(secret.title) copied — the clipboard clears itself in 60 seconds"
  }

  // MARK: - Privy

  var canSendPrivyOtp: Bool {
    !privyAppId.trimmed.isEmpty
      && !privyAppClientId.trimmed.isEmpty
      && !privyEmail.trimmed.isEmpty
      && !isLoading
      && !privyOtpSent
      && !privySessionActive
  }

  var canVerifyPrivyOtp: Bool {
    !privyOtpCode.trimmed.isEmpty && !isLoading
  }

  func sendPrivyOtp() async {
    guard canSendPrivyOtp else {
      statusText = "App ID, App Client ID, and Email are required"
      return
    }
    let email = privyEmail.trimmed
    SampleLog.i("Privy.otpInit", "starting email-OTP flow email=\(SampleLog.maskEmail(email))")
    SessionStore.provider = .privy
    SessionStore.privyAppId = privyAppId.trimmed
    SessionStore.privyAppClientId = privyAppClientId.trimmed
    SessionStore.privyEmail = email
    isLoading = true
    statusText = "Initializing Privy..."

    do {
      try PrivyAuthSample.shared.initialize(
        appId: privyAppId.trimmed,
        appClientId: privyAppClientId.trimmed
      )

      // As on Turnkey: only reuse a restored session when it belongs to this email.
      if await PrivyAuthSample.shared.hasActiveSession() {
        let sessionEmail = await PrivyAuthSample.shared.activeSessionEmail()
        if let sessionEmail, sessionEmail.caseInsensitiveCompare(email) == .orderedSame {
          SampleLog.i("Privy.otpInit", "existing session restored for this email — skipping OTP")
          privySessionActive = true
          statusText = "Existing Privy session restored — initialize Rain to continue"
          isLoading = false
          return
        }
        SampleLog.w(
          "Privy.otpInit",
          "restored session belongs to \(SampleLog.maskEmail(sessionEmail)), "
          + "not \(SampleLog.maskEmail(email)) — logging out"
        )
        await PrivyAuthSample.shared.logout()
      }

      statusText = "Sending OTP to \(email)..."
      try await PrivyAuthSample.shared.sendEmailOtp(email: email)
      privyOtpSent = true
      statusText = "OTP sent — check your email"
      SampleLog.i("Privy.otpInit", "OTP sent")
    } catch {
      SampleLog.e("Privy.otpInit", "failed: \(error.localizedDescription)")
      statusText = "Privy OTP init failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  func verifyPrivyOtp() async {
    guard privyOtpSent else {
      statusText = "Send OTP first"
      return
    }
    guard canVerifyPrivyOtp else {
      statusText = "OTP code required"
      return
    }

    SampleLog.i("Privy.otpVerify", "verifying OTP")
    isLoading = true
    statusText = "Verifying OTP..."

    do {
      try await PrivyAuthSample.shared.verifyEmailOtp(
        code: privyOtpCode.trimmed,
        email: privyEmail.trimmed
      )
      privySessionActive = true
      statusText = "Privy session active — initialize Rain to continue"
    } catch {
      SampleLog.e("Privy.otpVerify", "failed: \(error.localizedDescription)")
      statusText = "OTP verification failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  func initializeRainWithPrivy() async {
    guard privySessionActive else {
      statusText = "Verify OTP first"
      return
    }
    SampleLog.i("Privy.rainInit", "initializing Rain w/ Privy")
    isLoading = true
    statusText = "Initializing Rain with Privy..."

    do {
      // Privy keeps Ethereum and Solana accounts separate, so both are provisioned.
      let createdEvm = try await PrivyAuthSample.shared.ensureEthereumWallet()
      let createdSolana = try await PrivyAuthSample.shared.ensureSolanaWallet()
      if createdEvm || createdSolana {
        statusText = "Provisioned Privy wallets, initializing Rain..."
      }

      try await session.initializePrivy(
        privy: PrivyAuthSample.shared.privy,
        // Restart the OTP flow; a fresh login revives the provider (it watches the process-wide
        // Privy singleton), so Rain is not re-initialized.
        onSessionExpired: { [weak self] in
          SampleLog.w("Privy.session", "Privy session expired, re-auth required")
          Task { @MainActor [weak self] in
            guard let self else { return }
            privySessionActive = false
            privyOtpSent = false
            privyOtpCode = ""
            statusText = "Privy session expired — log in again"
          }
        }
      )
      await logResolvedAddresses(area: "Privy.rainInit")
      persistRainCredentials(.privy)
      isInitialized = session.isInitialized
      isRecovered = true
      statusText = "Rain initialized with Privy — wallet ready"
    } catch {
      SampleLog.e("Privy.rainInit", "failed: \(error.localizedDescription)")
      statusText = "Rain Privy init failed: \(error.localizedDescription)"
    }
    isLoading = false
  }

  // MARK: - Reset

  /// True while `clearSession()` runs, so the expiry hook ignores the logout it triggers.
  private var isClearingSession = false

  func clearSession() async {
    SampleLog.i("Home", "clearing session (provider logout + UI reset)")
    isClearingSession = true
    defer { isClearingSession = false }
    // Log out BEFORE resetting: `reset()` closes the provider, and a closed `RainProvider` refuses
    // `logout()` (terminal lifecycle), which would leave the vendor session alive — the next
    // passkey login is then refused up front and the next launch restores a "cleared" session.
    // Beta finding 2026-09-29 (B11).
    if let rainWalletProvider = session.rainWalletProvider {
      do {
        try await rainWalletProvider.logout()
      } catch {
        SampleLog.i("Home", "Rain Wallet logout failed: \(error.localizedDescription)")
      }
    }
    // Close the provider so its watcher does not report the logout as a death.
    session.reset()
    SessionStore.clear()
    // Real logout so the next run requires fresh auth (and resume detects no session).
    TurnkeyAuthSample.logout()
    await PrivyAuthSample.shared.logout()

    // Inputs reset (the provider choice is kept).
    seedFields()
    replacementPortalToken = ""
    turnkeyOtpId = nil
    turnkeyOtpCode = ""
    turnkeyOtpEncryptionBundle = nil
    turnkeySessionActive = false
    resetRainWalletCodeSteps()
    rainWalletSessionActive = false
    rainWalletAttachCodeSent = false
    rainWalletAttachCode = ""
    revealedSecret = nil
    rainWalletPhone = ""

    privyOtpSent = false
    privyOtpCode = ""
    privySessionActive = false
    isInitialized = false
    isRecovered = false
    statusText = "Session Cleared"
  }

  /// Portal is EVM-only; force the selection back to an EVM chain so it never reads/signs on Solana.
  func normalizeSelectedChain() {
    if mode == .portal && selectedChain.isSolana {
      selectedChain = .avalancheFuji
    }
  }

  private func logResolvedAddresses(area: String) async {
    let client = try? session.requireClient()
    let evm = try? await client?.getWalletAddress(chainId: WalletChain.avalancheFuji.chainId)
    let solana = try? await client?.getWalletAddress(chainId: WalletChain.solanaDevnet.chainId)
    SampleLog.i(
      area,
      "success — isInitialized=\(session.isInitialized) evm=\(evm ?? "nil") sol=\(solana ?? "nil")"
    )
  }
}

private extension WalletMode {
  init(_ provider: SessionStore.Provider) {
    switch provider {
    case .portal: self = .portal
    case .turnkey: self = .turnkey
    case .privy: self = .privy
    case .rainWallet: self = .rainWallet
    }
  }
}

private extension Optional where Wrapped == String {
  func matches(_ email: String) -> Bool {
    guard let value = self else { return false }
    return value.trimmed.caseInsensitiveCompare(email.trimmed) == .orderedSame
  }
}
