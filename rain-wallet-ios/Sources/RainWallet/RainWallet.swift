// RainWallet — the Rain-branded wallet provider.
//
// The wallet backend identity is embedded in the SDK, one per Rain environment. Hosts configure
// the Rain environment, how the app obtains wallet auth tokens from THEIR backend (minted with
// their Rain Api-Key — never in the app), optional behavior, and their own passkey domain if
// they use passkeys.
// Authentication runs inside the SDK, and the resolved `RainClient` exposes the same wallet
// surface as every other provider.
//
//     import RainWallet   // surfaces RainCore too
//
//     let provider = RainProvider(RainWalletConfig(
//         environment: .sandbox,
//         authTokenProvider: { contact in try await myBackend.walletAuthToken(for: contact) }
//     ))
//
//     await provider.awaitSessionRestore()
//     if !provider.hasActiveSession() {
//         try await provider.sendLoginCode(to: .email("user@example.com"))
//         try await provider.confirmLoginCode(code)   // or loginWithPasskey(anchor:)
//     }
//
//     let rain = try RainSdk.builder()
//         .rpcEndpoints([43114: "https://…"])
//         .register(provider)
//         .build()
//     let client = try await rain.provider(.rain)

import AuthenticationServices
import Combine
import Foundation
@_exported import RainCore
// SPI: Turnkey's managed-auth surface is @_spi(RainWallet) — this module is its only consumer.
// `internal` keeps the compiler-enforced guarantee that no Turnkey type leaks into our public API.
@_spi(RainWallet) internal import RainTurnkey

// MARK: - Auth state

/// Where Rain wallet authentication stands.
public enum RainWalletAuthState: Sendable, Equatable {
  /// The SDK is still restoring a possible previous session from secure storage.
  case loading
  /// A session is active; the provider can be resolved and wallet calls will succeed.
  case authenticated
  /// No session; run `sendLoginCode` / `confirmLoginCode`.
  case unauthenticated

  internal init(_ state: TurnkeyAuthState) {
    switch state {
    case .loading: self = .loading
    case .authenticated: self = .authenticated
    case .unauthenticated: self = .unauthenticated
    }
  }
}

// MARK: - Login contact

/// Where a one-time login (or contact-verification) code is delivered.
///
/// Inputs are normalized before use: emails are trimmed and lowercased (the same inbox in any
/// casing is one account), and phone numbers have user-visible formatting (spaces, dashes, dots,
/// parentheses) stripped down to E.164. What remains must be a plausible contact — `+` and 6–15
/// digits for a phone — or the call throws `RainError.invalidConfig` locally instead of a wrapped
/// backend rejection. The normalized string is the account identity, on both platforms.
public enum RainWalletContact: Sendable, Equatable {
  /// An email address.
  case email(String)
  /// A phone number in international format (e.g. "+1 555 123 4567") — the code arrives by SMS.
  case phone(String)

  internal var backing: TurnkeyLoginContact {
    switch self {
    case .email(let value): .email(value)
    case .phone(let value): .phone(value)
    }
  }

  internal init(_ backing: TurnkeyLoginContact) {
    switch backing {
    case .email(let value): self = .email(value)
    case .phone(let value): self = .phone(value)
    }
  }
}

// MARK: - Backend environment and wallet auth tokens

/// Which Rain deployment the wallet authenticates against. Each one fixes both the Rain API host
/// and the wallet backend organization, so a sandbox account can never sign into production.
public enum RainWalletEnvironment: Sendable, Equatable {
  /// Rain sandbox (`api-dev.rain.xyz`): test users, testnets.
  case sandbox
  /// Rain production (`api.rain.xyz`).
  case production

  internal var baseURL: URL {
    switch self {
    case .sandbox: URL(string: "https://api-dev.rain.xyz")!
    case .production: URL(string: "https://api.rain.xyz")!
    }
  }

  /// Rain's wallet backend identity for this environment. Public identifiers, not secrets:
  /// possession grants nothing — authentication still runs the one-time-code flow, and abuse is
  /// bounded by the backend's rate limits. Embedded so hosts configure only the environment.
  internal var organizationId: String {
    switch self {
    case .sandbox: "63495e45-8e64-42b5-b602-c68f019ca806"
    case .production: "306c2e82-5ae2-4be6-8b41-1ab0cc6b0ab5"
    }
  }
}

/// Mints a wallet auth token for the SDK's code flows. **Your backend** calls Rain's
/// `POST /v1/issuing/embedded-wallets/auth-tokens` with your Rain Api-Key and returns the
/// token (`wat_…`) to the app; this closure is how the app hands it to the SDK. Never embed
/// an Api-Key in the app.
///
/// The SDK calls it at the start of every code flow — `sendLoginCode` and
/// `sendContactVerificationCode`, with the contact the token must be bound to — and once more
/// if the token expires mid-flow. Passkey signup asks with `nil` (a contact-less token). Tokens
/// live ten minutes and are consumed by login, so return a fresh one each time. Throw to abort
/// the flow; a `RainError` passes through as-is, anything else surfaces as `providerError`.
public typealias RainWalletAuthTokenProvider = @Sendable (RainWalletContact?) async throws -> String

// MARK: - Key export

/// Which of the account's keys to export. Every Rain wallet account has exactly one key per
/// chain family, both derived from the single wallet seed.
public enum RainWalletKeyAccount: Sendable, Equatable, CaseIterable {
  /// The EVM account (secp256k1); exports as a 0x-prefixed 32-byte hex string.
  case ethereum
  /// The Solana account (ed25519); exports as the standard Base58 string Solana wallets import.
  case solana
}

// MARK: - Session state

/// The wallet session as seen at the SDK boundary. Observable via ``RainProvider/sessionState``
/// so a host can react to a session dying without waiting for a wallet call to fail.
public enum RainWalletSessionState: Sendable, Equatable {
  /// The SDK is still restoring persisted sessions (app launch).
  case loading
  /// A session exists and has not expired.
  case active(expiresAtEpochSeconds: TimeInterval)
  /// The session has expired. Re-authenticate.
  case expired
  /// No session (never logged in, logged out, or expired out).
  case unauthenticated

  internal init(_ state: TurnkeySessionState) {
    switch state {
    case .loading: self = .loading
    case .active(let expiresAt): self = .active(expiresAtEpochSeconds: expiresAt)
    case .expired: self = .expired
    case .unauthenticated: self = .unauthenticated
    }
  }
}

// MARK: - Session policy

/// Session-hardening policy for the Rain wallet provider.
///
/// Controls how the SDK guards wallet calls against session expiry and transient failures:
/// expiry is checked before every backend call, sessions inside `refreshBufferSeconds` of expiry
/// are refreshed proactively (when `autoRefresh` is on), an invalid-session failure is refreshed
/// and retried once, and transient failures on read paths are retried with exponential backoff.
/// Writes (sends, signing) are never retried on transient failures.
public struct RainWalletSessionPolicy: Sendable {
  /// Refresh the session when it is within this window of expiring.
  public var refreshBufferSeconds: TimeInterval
  /// When true the SDK refreshes the session itself; when false an expired session surfaces as
  /// `RainError.tokenExpired` and re-auth is the host's job.
  public var autoRefresh: Bool
  /// TTL in seconds requested for refreshed sessions; `nil` uses the backend default (900).
  public var refreshExpirationSeconds: Int?
  /// Retries (beyond the first attempt) for transient failures on idempotent reads.
  public var maxTransientRetries: Int
  /// First backoff delay; doubles per retry up to `maxRetryDelay`.
  public var initialRetryDelay: TimeInterval
  /// Backoff ceiling.
  public var maxRetryDelay: TimeInterval

  /// Traps on an invalid policy (a programmer error, like Android's `IllegalArgumentException`):
  /// buffer, retries and delays must be non-negative, `refreshExpirationSeconds` positive when
  /// set, and `maxRetryDelay >= initialRetryDelay`.
  public init(
    refreshBufferSeconds: TimeInterval = 60,
    autoRefresh: Bool = true,
    refreshExpirationSeconds: Int? = nil,
    maxTransientRetries: Int = 2,
    initialRetryDelay: TimeInterval = 0.5,
    maxRetryDelay: TimeInterval = 4
  ) {
    precondition(refreshBufferSeconds >= 0, "refreshBufferSeconds must be >= 0")
    precondition(refreshExpirationSeconds.map { $0 > 0 } ?? true, "refreshExpirationSeconds must be > 0")
    precondition(maxTransientRetries >= 0, "maxTransientRetries must be >= 0")
    precondition(initialRetryDelay >= 0, "initialRetryDelay must be >= 0")
    precondition(maxRetryDelay >= initialRetryDelay, "maxRetryDelay must be >= initialRetryDelay")
    self.refreshBufferSeconds = refreshBufferSeconds
    self.autoRefresh = autoRefresh
    self.refreshExpirationSeconds = refreshExpirationSeconds
    self.maxTransientRetries = maxTransientRetries
    self.initialRetryDelay = initialRetryDelay
    self.maxRetryDelay = maxRetryDelay
  }

  internal var backingPolicy: TurnkeySessionPolicy {
    TurnkeySessionPolicy(
      refreshBufferSeconds: refreshBufferSeconds,
      autoRefresh: autoRefresh,
      refreshExpirationSeconds: refreshExpirationSeconds,
      maxTransientRetries: maxTransientRetries,
      initialRetryDelay: initialRetryDelay,
      maxRetryDelay: maxRetryDelay
    )
  }
}

// MARK: - Configuration

/// Configuration for the Rain wallet provider. The wallet backend identity (Rain's organization)
/// is embedded in the SDK — hosts configure which Rain
/// environment to use, how the app obtains wallet auth tokens from their backend, and behavior.
public struct RainWalletConfig: Sendable {
  /// Which Rain API the wallet authenticates against. Defaults to production: pointing a build
  /// at the sandbox is an explicit choice.
  public let environment: RainWalletEnvironment
  /// How the app obtains wallet auth tokens from YOUR backend (see
  /// ``RainWalletAuthTokenProvider``). `nil` leaves only passkey login usable:
  /// ``RainProvider/sendLoginCode(to:)`` and ``RainProvider/sendContactVerificationCode(to:)``
  /// throw `RainError.invalidConfig`.
  public let authTokenProvider: RainWalletAuthTokenProvider?
  /// The passkey relying-party domain — a web domain YOUR app controls (e.g. "example.com").
  /// `nil` disables the passkey methods (they throw `RainError.invalidConfig`).
  ///
  /// Requirements: the domain serves `/.well-known/apple-app-site-association` listing your
  /// app under `webcredentials`, and the app carries the Associated Domains entitlement
  /// `webcredentials:<domain>`. Passkeys are bound to this domain forever — changing it strands
  /// every passkey your users created — and the value is one-shot per app launch.
  public let passkeyDomain: String?
  /// When true (the default), every send on a chain the wallet backend can broadcast on is
  /// gas-sponsored — transfers, collateral withdrawals, Auth Pull approvals alike: the backend
  /// builds and pays the network fee and the user needs no native gas token. Fee estimates
  /// still quote the on-chain cost — what the user saves. Sponsorship cost passes through to
  /// the partner. Solana sends are sponsored
  /// too (network fee only — rent for a first-time recipient's token account stays the sender's).
  /// Set false where sponsorship is not enabled for the backend organization, or the backend
  /// rejects the sends.
  public let sponsorGas: Bool
  /// Expiry/refresh/retry behavior for the session guarding every wallet call.
  public let sessionPolicy: RainWalletSessionPolicy
  /// Re-auth hook: invoked once per session death when the session dies and cannot be refreshed.
  /// Not necessarily on the main thread; hop to the main actor before touching UI, and never
  /// call back into the SDK synchronously from it. Restart authentication from here
  /// (`sendLoginCode` / `confirmLoginCode`).
  public let onSessionExpired: (@Sendable () -> Void)?

  public init(
    environment: RainWalletEnvironment = .production,
    authTokenProvider: RainWalletAuthTokenProvider? = nil,
    passkeyDomain: String? = nil,
    sponsorGas: Bool = true,
    sessionPolicy: RainWalletSessionPolicy = RainWalletSessionPolicy(),
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) {
    self.environment = environment
    self.authTokenProvider = authTokenProvider
    self.passkeyDomain = passkeyDomain
    self.sponsorGas = sponsorGas
    self.sessionPolicy = sessionPolicy
    self.onSessionExpired = onSessionExpired
  }
}

// MARK: - Provider

/// Registrable descriptor for the Rain wallet provider.
///
/// The SDK owns authentication: send a one-time login code to the user's email, confirm it
/// (first-time signup and returning login are handled transparently, and the account's EVM and
/// Solana wallets are provisioned automatically), then register the provider and resolve
/// `rain.provider(.rain)`.
///
/// The underlying wallet-backend configuration is one-shot per app launch — constructing a second
/// provider with *different* ids makes every auth call on it throw `invalidConfig` until the app
/// relaunches. The Rain wallet provider cannot be registered alongside the Turnkey provider.
public struct RainProvider: ProviderDescriptor {
  internal let backing: TurnkeyProvider
  /// Flipped by ``close()``. A reference so every copy of this value sees the same lifecycle.
  private let lifecycle = Lifecycle()

  private final class Lifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    func close() { lock.withLock { closed = true } }
  }

  /// Auth and export calls refuse after ``close()`` — the provider is inert, not "logged out".
  private func requireOpen() throws {
    if lifecycle.isClosed {
      throw RainError.invalidConfig(details: "This RainProvider was closed; build a new one")
    }
  }

  public init(_ config: RainWalletConfig = RainWalletConfig()) {
    // The backend asks with its own contact type; translate to the host's on the way out.
    var backingTokenProvider: TurnkeyManagedAuthBackend.TokenProvider?
    if let provide = config.authTokenProvider {
      backingTokenProvider = { (contact: TurnkeyLoginContact?) async throws -> String in
        try await provide(contact.map { RainWalletContact($0) })
      }
    }
    self.backing = TurnkeyProvider(
      TurnkeyConfig(
        organizationId: config.environment.organizationId,
        authBackend: TurnkeyManagedAuthBackend(
          baseURL: config.environment.baseURL,
          tokenProvider: backingTokenProvider
        ),
        rpId: config.passkeyDomain,
        sessionPolicy: config.sessionPolicy.backingPolicy,
        sponsorGas: config.sponsorGas,
        onSessionExpired: config.onSessionExpired
      )
    )
  }

  /// Test seam: wraps an existing backing provider, bypassing the one-shot process-wide
  /// backend configuration that the public init runs.
  internal init(backing: TurnkeyProvider) {
    self.backing = backing
  }

  public var id: ProviderId { .rain }

  /// Follows the backing provider: `.export` (recovery phrase and per-account keys),
  /// `.multiChain` (EVM + Solana accounts), and `.gasSponsorship` when
  /// `RainWalletConfig.sponsorGas` is on. Signing is not biometric-gated; passkeys and Face ID
  /// appear only at login.
  public var capabilities: Set<Capability> { backing.capabilities }

  public func create(context: ProviderContext) async throws -> any WalletProvider {
    try await backing.create(context: context)
  }

  // MARK: Authentication (email one-time codes)

  /// Where authentication stands, over time. Emits on every auth change; finishes never.
  /// `.unauthenticated` in a fresh install; `.authenticated` once a session is live (restored,
  /// or established via a login code or passkey). Pairs with ``currentAuthState()`` the way
  /// ``sessionState`` pairs with ``currentSessionState()``.
  public var authState: AnyPublisher<RainWalletAuthState, Never> {
    backing.authState.map(RainWalletAuthState.init).removeDuplicates().eraseToAnyPublisher()
  }

  /// Snapshot of ``authState`` right now. `.unauthenticated` after ``close()``.
  public func currentAuthState() -> RainWalletAuthState {
    lifecycle.isClosed ? .unauthenticated : RainWalletAuthState(backing.currentAuthState())
  }

  /// Sends a one-time login code to an email address or phone number (SMS).
  public func sendLoginCode(to contact: RainWalletContact) async throws {
    try requireOpen()
    try await backing.sendLoginCode(to: contact.backing)
  }

  /// Confirms the code from ``sendLoginCode(to:)``, signing the user up on first login, and
  /// provisions the account's EVM and Solana wallets.
  ///
  /// One active login per user: a successful login invalidates the user's sessions everywhere
  /// else, so logging in on a second device logs the first one out (where `onSessionExpired`
  /// fires on its next use). Same behavior on the Android SDK.
  public func confirmLoginCode(_ code: String) async throws {
    try requireOpen()
    try await backing.confirmLoginCode(code)
  }

  // MARK: Passkeys

  /// Signs an existing user in with a passkey. `anchor` is the window/scene the system passkey
  /// sheet presents from.
  public func loginWithPasskey(anchor: ASPresentationAnchor) async throws {
    try requireOpen()
    try await backing.loginWithPasskey(anchor: anchor)
  }

  /// Creates a NEW account with a passkey; one wallet with EVM + Solana accounts is provisioned
  /// atomically. Every call mints a fresh account — returning users must use
  /// ``loginWithPasskey(anchor:)`` (or a login code), or they end up with a second, empty wallet.
  /// Asks ``RainWalletConfig/authTokenProvider`` for a contact-less token (`nil` contact) and
  /// shows two biometric prompts: registration, then sign-in.
  public func signUpWithPasskey(anchor: ASPresentationAnchor) async throws {
    try requireOpen()
    try await backing.signUpWithPasskey(anchor: anchor)
  }

  /// Registers a passkey on the current account (active session required) so the user can sign
  /// in with it next time.
  public func addPasskey(anchor: ASPresentationAnchor) async throws {
    try requireOpen()
    try await backing.addPasskey(anchor: anchor)
  }

  // MARK: Attach a login contact

  /// Sends a verification code to a contact the user wants to ATTACH to the current account
  /// (active session required) — e.g. adding an email to a passkey-created account. Once
  /// confirmed, the contact is a login method for this account. Accounts are never merged: if
  /// the contact already belongs to another account, attaching it here does not move wallets.
  public func sendContactVerificationCode(to contact: RainWalletContact) async throws {
    try requireOpen()
    try await backing.sendContactVerificationCode(to: contact.backing)
  }

  /// Confirms the code from ``sendContactVerificationCode(to:)`` and attaches the contact,
  /// verified. A wrong code throws `RainError.invalidLoginCode` — re-prompt and retry. A
  /// contact that is already another wallet's login in this app throws
  /// `RainError.unauthorized` (RAIN_202) and ends the attempt — steer the user to sign in with it.
  public func confirmContactVerification(_ code: String) async throws {
    try requireOpen()
    try await backing.confirmContactVerification(code)
  }

  /// Clears the stored session (full logout). Safe no-op when none exists. Returns only once
  /// `authState` / `hasActiveSession()` reflect the logout, so it is safe to read them right
  /// after.
  public func logout() async throws {
    try requireOpen()
    try await backing.logout()
  }

  /// Waits for the asynchronous session restore that follows configuration, so a returning
  /// user's session can be reused without re-running the login-code flow.
  public func awaitSessionRestore(timeout: TimeInterval = 5) async {
    await backing.awaitSessionRestore(timeout: timeout)
  }

  /// True when an unexpired session is already loaded and the login-code flow can be skipped.
  public func hasActiveSession() -> Bool {
    !lifecycle.isClosed && backing.hasActiveSession()
  }

  // MARK: Key export

  /// Exports the wallet's 12-word recovery phrase, decrypted on-device. The account has ONE
  /// wallet seed covering every chain family, so this single phrase restores both the EVM and
  /// Solana accounts in any BIP-39 wallet.
  ///
  /// The SDK never logs or persists the returned value. Everything after the return is the
  /// host's responsibility: gate the call (e.g. behind biometrics), show the phrase without
  /// screenshots/screen recording where possible, and don't place it on the pasteboard.
  /// Requires an active session — throws `RainError.tokenExpired` otherwise.
  public func exportRecoveryPhrase() async throws -> String {
    try requireOpen()
    return try await backing.exportMnemonic()
  }

  /// Exports one account's private key, decrypted on-device: `.ethereum` as a 0x-prefixed
  /// 32-byte hex string (the form Ethereum wallets import), `.solana` as the standard Base58
  /// string Solana wallets import. The same formats are returned by the Android SDK.
  ///
  /// The SDK never logs or persists the returned value; gating and safe display are the host's
  /// responsibility (see ``exportRecoveryPhrase()``). Requires an active session — throws
  /// `RainError.tokenExpired` otherwise.
  public func exportPrivateKey(_ account: RainWalletKeyAccount) async throws -> String {
    try requireOpen()
    return try await backing.exportPrivateKey(family: account == .ethereum ? .ethereum : .solana)
  }

  // MARK: Session

  /// The wallet session over time. Emits on every auth/session change and when an active session
  /// passes its expiry.
  public var sessionState: AnyPublisher<RainWalletSessionState, Never> {
    backing.sessionState.map(RainWalletSessionState.init).eraseToAnyPublisher()
  }

  /// Snapshot of ``sessionState`` right now.
  public func currentSessionState() -> RainWalletSessionState {
    RainWalletSessionState(backing.currentSessionState())
  }

  /// Forces a session refresh (extended expiry) regardless of remaining lifetime. Throws
  /// `RainError.tokenExpired` when the session cannot be refreshed — re-authenticate.
  public func refreshSession() async throws {
    try await backing.refreshSession()
  }

  /// Stops the passive session watcher and makes this provider inert. Call it when discarding the
  /// provider (e.g. rebuilding the SDK for a new login) so a stale provider can never fire its
  /// expiry hook again. Afterwards every authentication and export call throws
  /// `RainError.invalidConfig` (RAIN_102), `authState` reads `.unauthenticated` and
  /// ``hasActiveSession()`` is false. ``sessionState`` / ``currentSessionState()`` keep reporting
  /// the process-wide backend session, so cancel your subscription when you discard the provider.
  /// Idempotent. Same contract as the Android SDK.
  public func close() {
    lifecycle.close()
    backing.close()
  }
}
