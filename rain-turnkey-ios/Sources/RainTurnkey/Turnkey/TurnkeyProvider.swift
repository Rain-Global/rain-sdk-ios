import AuthenticationServices
import Combine
import Foundation
import TurnkeySwift
@_spi(RainAdapter) import RainCore

/// Configuration for the Turnkey provider.
///
/// Public mode is **bring-your-own** (`init(turnkey:...)`): the host drives Turnkey's Swift SDK
/// (passkeys / auth proxy / OAuth / OTP) and hands the authenticated `TurnkeyContext` to Rain;
/// the SDK never touches authentication.
///
/// A second, **managed** mode (`init(organizationId:authBackend:...)`, where the SDK owns the
/// login flows against rain-api) exists behind `@_spi(RainWallet)` and ships to hosts only
/// through the `RainWallet` module.
///
/// `@unchecked Sendable`: `TurnkeyContext` is a reference type with mutable published state that
/// Rain reads from arbitrary executors. BYO host contract: finish authentication before handing
/// the context to Rain, and don't mutate it (re-auth, logout, wallet switch) while Rain calls are
/// in flight — after such changes, build a new `RainSdk` / re-resolve the provider.
public struct TurnkeyConfig: @unchecked Sendable {
  internal enum Mode: @unchecked Sendable {
    /// Host-authenticated context; the SDK exposes no auth surface.
    case byoContext(TurnkeyContext)
    /// SDK-managed auth: codes, signup and passkey signup go through rain-api (`authBackend`);
    /// the Turnkey organization is what sessions and passkey login are scoped to. `rpId` is the
    /// passkey relying-party domain; `nil` disables passkey flows.
    case managed(
      organizationId: String,
      rpId: String?,
      authBackend: TurnkeyManagedAuthBackend
    )
  }

  internal let mode: Mode
  /// When true, every EVM send on a Turnkey broadcast chain is sponsored — transfers, collateral
  /// withdrawals, Auth Pull approvals and raw `sendTransaction` calls alike: Turnkey's Gas
  /// Station builds and pays the fee (gasless for the end user). Fee estimates still quote the
  /// on-chain cost — what the user saves — so hosts can display it. Sponsorship cost passes
  /// through to the partner that turns this on. Solana sends are
  /// sponsored too (network fee only: rent for a first-time recipient's token account is a
  /// separate Turnkey toggle, off by default, so the sender must still hold it).
  ///
  /// Defaults to true: sponsorship is the product, and Turnkey enables it at the parent
  /// organization level. On an organization where it is not enabled, Turnkey rejects sponsored
  /// sends, so pass false there. Sponsored sends have no client-side revert preflight; failures
  /// surface through Turnkey's decoded FAILED status.
  public let sponsorGas: Bool
  /// Optional explicit EVM wallet address. When `nil`, Rain uses the first Ethereum account from
  /// the Turnkey context.
  public let walletAddress: String?
  /// Expiry/refresh/retry behavior for the session guarding every wallet call.
  public let sessionPolicy: TurnkeySessionPolicy
  /// Re-auth hook: invoked once per session death when the Turnkey session dies and cannot be
  /// refreshed — whether that is discovered during a wallet call or by the passive session
  /// watcher. Not necessarily on the main thread; hop to the main actor before touching UI,
  /// and never call back into the SDK synchronously from it. Restart authentication from here
  /// (in managed mode: `sendLoginCode` / `confirmLoginCode` again).
  public let onSessionExpired: (@Sendable () -> Void)?

  /// Bring-your-own mode: `turnkey` is an already-authenticated Turnkey context.
  public init(
    turnkey: TurnkeyContext,
    walletAddress: String? = nil,
    sessionPolicy: TurnkeySessionPolicy = TurnkeySessionPolicy(),
    sponsorGas: Bool = true,
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) {
    self.mode = .byoContext(turnkey)
    self.walletAddress = walletAddress
    self.sponsorGas = sponsorGas
    self.sessionPolicy = sessionPolicy
    self.onSessionExpired = onSessionExpired
  }

  /// Managed mode: the SDK configures Turnkey against this organization and owns authentication
  /// — one-time codes, signup and passkey signup through rain-api, passkey login through
  /// Turnkey directly.
  ///
  /// Not public API. `@_spi(RainWallet)`: managed auth ships exclusively through the
  /// `RainWallet` module's `RainProvider` — the public Turnkey provider is bring-your-own,
  /// where the host owns authentication.
  ///
  /// The underlying Turnkey configuration is one-shot per app launch — constructing a second
  /// managed provider with *different* ids leaves the first configuration in place and makes
  /// every auth call on the new provider throw `invalidConfig`.
  ///
  /// One-time-code login and signup run against rain-api (`authBackend`), riding on a wallet
  /// auth token the host's backend mints; `authBackend.tokenProvider == nil` leaves only
  /// passkey login usable (the code flows throw `invalidConfig`). Logging in does NOT revoke
  /// the user's other sessions any more (rain-api's `/login` has no `invalidateExisting`) —
  /// a second device logging in leaves the first one live.
  @_spi(RainWallet)
  public init(
    organizationId: String,
    authBackend: TurnkeyManagedAuthBackend,
    rpId: String? = nil,
    walletAddress: String? = nil,
    sessionPolicy: TurnkeySessionPolicy = TurnkeySessionPolicy(),
    sponsorGas: Bool = true,
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) {
    self.mode = .managed(
      organizationId: organizationId,
      rpId: rpId,
      authBackend: authBackend
    )
    self.walletAddress = walletAddress
    self.sponsorGas = sponsorGas
    self.sessionPolicy = sessionPolicy
    self.onSessionExpired = onSessionExpired
  }
}

/// Registrable descriptor for the Turnkey wallet provider.
///
/// Turnkey is bundled inside `RainCore` for now (it will graduate to a standalone `rain-turnkey`
/// module later). It implements `ProviderDescriptor` like any adapter, but relies on the core-internal
/// `ProviderContext` EVM chain reader that out-of-core adapters cannot reach yet — that must be
/// widened when the module is extracted.
///
/// ```swift
/// let rain = try RainSdk.builder()
///     .rpcEndpoints([43114: "https://…"])
///     .register(TurnkeyProvider(TurnkeyConfig(turnkey: turnkeyContext)))
///     .build()
/// let client = try await rain.provider(.turnkey)
/// ```
/// `@unchecked Sendable`: `context` is the Turnkey context (a reference type with mutable
/// published state — the same value `TurnkeyConfig` already carries under `@unchecked`), and the
/// coordinator / managed-auth controller are internally synchronized classes. The provider itself
/// is immutable after init.
public struct TurnkeyProvider: ProviderDescriptor, @unchecked Sendable {
  private let config: TurnkeyConfig
  private let coordinator: TurnkeySessionCoordinator
  private let context: TurnkeyContextProtocol
  /// Present in managed mode only; owns the email-OTP flow.
  private let managedAuth: TurnkeyManagedAuthController?

  public init(_ config: TurnkeyConfig) {
    // Turnkey vendor errors classify via core's extensible mapper (like Portal / Privy);
    // registering here guarantees the mapper is live before any Turnkey-backed call can fail —
    // including managed-auth calls, which happen before any wallet is resolved.
    TurnkeyErrorMapping.registerOnce()

    let context: TurnkeyContextProtocol
    let managedAuth: TurnkeyManagedAuthController?
    switch config.mode {
    case .byoContext(let turnkey):
      context = turnkey
      managedAuth = nil
    case .managed(let organizationId, let rpId, let authBackend):
      // One-shot per process; a mismatch is remembered and thrown from every auth call.
      let configurationError = TurnkeyManagedConfigurator.configure(
        organizationId: organizationId,
        rpId: rpId
      )
      let shared = TurnkeyManagedConfigurator.sharedContext()
      context = shared
      managedAuth = TurnkeyManagedAuthController(
        context: shared,
        configurationError: configurationError,
        rpId: rpId,
        api: RainApiAuthClient(baseURL: authBackend.baseURL),
        tokenProvider: authBackend.tokenProvider
      )
    }

    self.init(config: config, context: context, managedAuth: managedAuth)
  }

  /// Test seam: injects the context (and managed-auth controller) directly.
  internal init(
    config: TurnkeyConfig,
    context: TurnkeyContextProtocol,
    managedAuth: TurnkeyManagedAuthController?
  ) {
    self.config = config
    self.context = context
    self.managedAuth = managedAuth
    self.coordinator = TurnkeySessionCoordinator(
      turnkey: context,
      policy: config.sessionPolicy,
      onSessionExpired: config.onSessionExpired
    )
  }

  public var id: ProviderId { .turnkey }

  /// The rain-api backend a managed provider was built with; `nil` in BYO mode. Lets RainWallet
  /// (and its tests) see what its configuration translated to.
  @_spi(RainWallet)
  public var managedAuthBackend: TurnkeyManagedAuthBackend? {
    if case .managed(_, _, let authBackend) = config.mode { return authBackend }
    return nil
  }

  /// Turnkey holds EVM + Solana accounts (`.multiChain`) and can export keys (`.export`); with
  /// `TurnkeyConfig.sponsorGas` on it also advertises `.gasSponsorship`. Signing itself is NOT
  /// biometric-gated — the vendor's enclave key uses a `.none` auth policy — so `.biometricGate`
  /// is deliberately absent. The same function feeds the resolved wallet's set, so the two cannot
  /// drift.
  public var capabilities: Set<Capability> {
    TurnkeyWalletProviderAdapter.capabilities(sponsorGas: config.sponsorGas)
  }

  /// The Turnkey session as seen at the Rain boundary, over time. Emits on every Turnkey
  /// auth/session change and when an active session passes its expiry, so a host can react to
  /// a session dying silently without waiting for a wallet call to fail.
  public var sessionState: AnyPublisher<TurnkeySessionState, Never> {
    coordinator.sessionStates
  }

  /// Snapshot of `sessionState` right now.
  public func currentSessionState() -> TurnkeySessionState {
    coordinator.currentState()
  }

  /// Forces a Turnkey session refresh (new JWT, extended expiry) regardless of remaining
  /// lifetime. Throws `RainError.tokenExpired` when the session cannot be refreshed — the
  /// host must re-authenticate.
  public func refreshSession() async throws {
    try await coordinator.refreshNow()
  }

  /// Stops the passive session watcher. Call when discarding this provider (e.g. rebuilding
  /// the SDK for a new login) so a stale provider stops observing the process-wide Turnkey
  /// singleton and can never fire its expiry hook again.
  public func close() {
    coordinator.stopMonitoring()
  }

  public func create(context: ProviderContext) async throws -> any WalletProvider {
    // The watcher only exists to drive the host's re-auth hook; without one there is nothing
    // to notify and no reason to hold a subscription on the Turnkey singleton.
    if config.onSessionExpired != nil {
      coordinator.startMonitoring()
    }

    let provider = TurnkeyWalletProviderAdapter(
      turnkey: self.context, // the Turnkey context — `context` alone is the ProviderContext parameter
      networkConfigs: context.networkConfigs,
      walletAddress: config.walletAddress,
      sponsorGas: config.sponsorGas,
      chainReader: context.evmChainReader,
      solanaSupport: context.solanaSupport,
      tokenStore: context.tokenStore,
      sessionCoordinator: coordinator
    )
    // Probe the wallet so an unusable context fails fast at resolution time (parity with the
    // old initializeTurnkey behaviour). In managed mode this is also what surfaces "resolved
    // before authentication finished" as a clean error.
    _ = try await provider.address()
    return provider
  }
}

// MARK: - Managed authentication (email OTP)

// Not public API. `@_spi(RainWallet)`: this entire surface exists for the `RainWallet` module,
// which wraps a managed provider under wallet-neutral names. The public Turnkey provider is
// bring-your-own — the host authenticates with Turnkey's SDK itself and hands in the context.
extension TurnkeyProvider {
  /// Where managed authentication stands. `.unauthenticated` in a fresh install;
  /// `.authenticated` once a session is live (restored, or established via the OTP flow).
  /// Always `.unauthenticated`-shaped in BYO mode — the host owns auth there.
  @_spi(RainWallet)
  public func currentAuthState() -> TurnkeyAuthState {
    managedAuth?.currentAuthState() ?? .unauthenticated
  }

  /// Managed auth state over time. Emits on every auth change; finishes never.
  @_spi(RainWallet)
  public var authState: AnyPublisher<TurnkeyAuthState, Never> {
    managedAuth?.authState ?? Just(.unauthenticated).eraseToAnyPublisher()
  }

  /// Sends a one-time login code to an email address or (SMS) phone number. Managed mode only.
  @_spi(RainWallet)
  public func sendLoginCode(to contact: TurnkeyLoginContact) async throws {
    try await requireManagedAuth().sendLoginCode(to: contact)
  }

  /// Confirms the code from ``sendLoginCode(to:)``, signing the user up on first login, and
  /// ensures the account has Ethereum and Solana accounts on one wallet seed. Managed mode only.
  /// Throws `RainError.invalidLoginCode` when the code is rejected (wrong, expired, or already
  /// used) — re-prompt the user rather than restarting the flow.
  @_spi(RainWallet)
  public func confirmLoginCode(_ code: String) async throws {
    try await requireManagedAuth().confirmLoginCode(code)
  }

  /// Signs an existing user in with a passkey. Managed mode only; requires the relying-party
  /// domain in the managed configuration.
  @_spi(RainWallet)
  public func loginWithPasskey(anchor: ASPresentationAnchor) async throws {
    try await requireManagedAuth().loginWithPasskey(anchor: anchor)
  }

  /// Creates a NEW account with a passkey (one wallet, both chain families, atomically).
  /// Returning users must use ``loginWithPasskey(anchor:)`` — every call here mints a fresh
  /// account. Managed mode only.
  @_spi(RainWallet)
  public func signUpWithPasskey(anchor: ASPresentationAnchor) async throws {
    try await requireManagedAuth().signUpWithPasskey(anchor: anchor)
  }

  /// Registers a passkey on the current account (active session required) so the user can sign
  /// in with it later. Managed mode only.
  @_spi(RainWallet)
  public func addPasskey(anchor: ASPresentationAnchor) async throws {
    try await requireManagedAuth().addPasskey(anchor: anchor)
  }

  /// Sends a verification code to a contact to ATTACH to the current account (active session
  /// required). Managed mode only.
  @_spi(RainWallet)
  public func sendContactVerificationCode(to contact: TurnkeyLoginContact) async throws {
    try await requireManagedAuth().sendContactVerificationCode(to: contact)
  }

  /// Confirms the code from ``sendContactVerificationCode(to:)`` and attaches the contact,
  /// verified, as a login method for this account. Managed mode only.
  @_spi(RainWallet)
  public func confirmContactVerification(_ code: String) async throws {
    try await requireManagedAuth().confirmContactVerification(code)
  }

  /// Clears the stored session (full logout). Safe no-op when none exists. Managed mode only —
  /// throws `invalidConfig` in BYO mode, where the host owns the session.
  ///
  /// Async because the vendor flips the live auth state from a main-actor Task after wiping
  /// storage: the call returns only once `authState` / `hasActiveSession()` reflect the logout.
  @_spi(RainWallet)
  public func logout() async throws {
    try await requireManagedAuth().logout()
  }

  /// Waits for the asynchronous session restore that follows configuration, so a returning
  /// user's session can be reused without re-running the OTP flow. No-op in BYO mode.
  @_spi(RainWallet)
  public func awaitSessionRestore(timeout: TimeInterval = 5) async {
    await managedAuth?.awaitSessionRestore(timeout: timeout)
  }

  /// True when an unexpired session is already loaded and the OTP flow can be skipped.
  @_spi(RainWallet)
  public func hasActiveSession() -> Bool {
    managedAuth?.hasActiveSession() ?? false
  }

  /// Exports the wallet's 12-word mnemonic phrase, decrypted on-device — one seed per account,
  /// so a single phrase restores every chain family. Managed mode only. The SDK never logs or
  /// persists the value; gating (e.g. biometrics) and safe display are the host's responsibility.
  @_spi(RainWallet)
  public func exportMnemonic() async throws -> String {
    try await requireManagedAuth().exportMnemonic()
  }

  /// Exports one account's private key, decrypted on-device: `.ethereum` as a 0x-prefixed
  /// 32-byte hex string, `.solana` as plain Base58 of privkey‖pubkey — the formats the Android SDK
  /// also returns. Managed mode only. The SDK never logs or persists the value; gating and safe
  /// display are the host's responsibility.
  @_spi(RainWallet)
  public func exportPrivateKey(family: TurnkeyKeyFamily) async throws -> String {
    try await requireManagedAuth().exportPrivateKey(family: family)
  }

  private func requireManagedAuth() throws -> TurnkeyManagedAuthController {
    guard let managedAuth else {
      throw RainError.invalidConfig(details:
        "Authentication methods are only available in managed mode — construct the provider with "
        + "TurnkeyConfig(organizationId:authBackend:); in bring-your-own mode the host owns "
        + "authentication")
    }
    return managedAuth
  }
}
