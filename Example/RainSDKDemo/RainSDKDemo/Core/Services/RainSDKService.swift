import Combine
import Foundation
import RainCore
import RainTurnkey
import RainPortal
import RainPrivy
import RainWallet
import PortalSwift
import PrivySDK
import TurnkeySwift

/// App-side holder around the modular SDK.
///
/// The demo picks a provider at runtime (Portal, Turnkey, or Privy), so it builds the ``RainSdk``
/// lazily once the user supplies credentials and then keeps the resolved ``RainClient`` here.
/// Screens read `rain` / `client` directly — there is no wrapper layer over the SDK surface.
/// Setup failures the demo can explain better than the vendor error can.
enum PortalWalletSetupError: LocalizedError {
  case walletNotOnThisDevice

  var errorDescription: String? {
    switch self {
    case .walletNotOnThisDevice:
      return "This Portal client already has a wallet, but its signing share is not on this "
        + "device. Recover it from a backup, or use a client ID dedicated to this device."
    }
  }
}

@MainActor
final class RainSDKService: ObservableObject {
  static let shared = RainSDKService()

  enum ActiveProvider {
    case none
    case portal
    case turnkey
    case privy
    case rainWallet
  }

  /// The built SDK registry (Rain API + wallet-agnostic building). Nil before initialization.
  private(set) var rain: RainSdk?

  /// The provider-backed client (address, balances, send, withdraw). Nil before initialization.
  private(set) var client: RainClient?

  /// Holds the `Portal` for provider-only APIs (wallet generation, backup/recover). Boxed because
  /// the hook fires synchronously off the main actor — an actor hop would land too late.
  private final class PortalBox: @unchecked Sendable {
    var value: Portal?
  }

  private let portalBox = PortalBox()

  @Published private(set) var isInitialized = false

  /// Provider behind the last successful initialize; used to gate provider-specific UI.
  @Published private(set) var activeProvider: ActiveProvider = .none

  /// The active provider's `sessionState` as a display model; nil before resolution.
  @Published private(set) var sessionStatus: WalletSessionStatus?

  /// Typed because the session surface lives on the provider, not on `RainClient`.
  private enum ProviderHandle {
    case portal(RainPortal.PortalProvider)
    case turnkey(TurnkeyProvider)
    case privy(PrivyProvider)
    case rainWallet(RainWallet.RainProvider)

    func close() {
      switch self {
      case .portal(let provider): provider.close()
      case .turnkey(let provider): provider.close()
      case .privy(let provider): provider.close()
      case .rainWallet(let provider): provider.close()
      }
    }
  }

  private var providerHandle: ProviderHandle?
  private var sessionSubscription: AnyCancellable?

  /// Network the feature screens operate on, selected via the home-screen dropdown.
  @Published var selectedChain: WalletChain = .avalancheFuji

  /// The demo's Rain API client, built from the Api-Key + userId entered on the home screen.
  /// Calling the Rain API is the host's job, not the SDK's — see `RainApiClient`. Independent of
  /// the SDK lifecycle: it needs no wallet, only credentials.
  private(set) var rainApi: RainApiClient?

  private init() {}

  /// True once an Api-Key and userId have been supplied.
  var isRainApiConfigured: Bool { rainApi != nil }

  /// Builds (or replaces) the Rain API client from the credentials. Empty input clears it.
  func configureRainApi(apiKey: String, userId: String) {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = userId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !user.isEmpty else {
      rainApi = nil
      return
    }
    rainApi = RainApiClient(environment: SampleEnvironment.rainApi, apiKey: key, userId: user)
  }

  /// The Rain API client, or throws when no credentials were supplied.
  func requireRainApi() throws -> RainApiClient {
    guard let rainApi else {
      throw NSError(
        domain: "RainSDKDemo", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Rain Api-Key and User ID required"]
      )
    }
    return rainApi
  }

  /// The user's collateral contract for `chain`, with each token's name/symbol/decimals resolved
  /// by the SDK from its address (`RainSdk.tokenMetadata`: registry, registered tokens, on-chain
  /// reads). Rain provisions one contract per chain family (Solana cluster exact, any EVM otherwise).
  func fetchCollateralContract(for chain: WalletChain) async throws -> CollateralContract? {
    guard let contract = try await requireRainApi()
      .fetchCollateralContracts()
      .first(where: { chain.ownsCollateralContract(chainId: $0.chainId) })
    else { return nil }

    // Enrichment needs the SDK (RPC endpoints); before it is built the tokens stay unnamed.
    guard let rain else { return contract }
    var tokens = contract.tokens
    for index in tokens.indices {
      // Throws for a malformed address, a chain without an RPC endpoint, or decimals the SDK
      // refuses (outside 0...77); nil means the chain simply could not answer. Both leave the
      // token unnamed and un-withdrawable in the UI, with the reason logged.
      let info: TokenInfo?
      do {
        info = try await rain.tokenMetadata(chainId: contract.chainId, address: tokens[index].address)
      } catch {
        SampleLog.w("RainApi", "token \(tokens[index].address) rejected: \(error.localizedDescription)")
        continue
      }
      guard let info else { continue }
      tokens[index].name = info.name
      tokens[index].symbol = info.symbol
      tokens[index].decimals = info.decimals
    }
    return CollateralContract(
      id: contract.id,
      chainId: contract.chainId,
      proxyAddress: contract.proxyAddress,
      controllerAddress: contract.controllerAddress,
      depositAddress: contract.depositAddress,
      adminAddresses: contract.adminAddresses,
      contractVersion: contract.contractVersion,
      tokens: tokens
    )
  }

  /// The tokens this demo knows by name: an SPL mint carries no on-chain symbol (and Turnkey's
  /// asset index skips devnet), while on EVM the SDK's built-in registry is mainnet-only.
  static let demoTokens: [TokenInfo] = WalletChain.selectable.map(\.defaultTokenInfo)

  /// Builds the SDK with the Portal provider (EVM chains only — Portal holds no Solana account).
  func initializePortal(
    sessionToken: String,
    onSessionTokenNeeded: (@Sendable () async throws -> String?)? = nil,
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) async throws {
    RainLogger.isEnabled = true
    closeActiveProvider()
    // Qualified: PortalSwift exports its own `PortalProvider`.
    let provider = RainPortal.PortalProvider(
      PortalConfig(
        sessionToken: sessionToken,
        onSessionTokenNeeded: onSessionTokenNeeded,
        onSessionExpired: onSessionExpired
      )
    ) { [portalBox] portal in
      // Re-fired after every token refresh.
      portalBox.value = portal
    }
    let sdk = try builder(networkConfigs: WalletChain.evmNetworkConfigs)
      .register(provider)
      .build()
    try await resolve(sdk: sdk, providerId: .portal, provider: .portal)
    bind(.portal(provider), states: provider.sessionState.map(\.status))
  }

  /// Ensures this device can sign for the Portal client, running MPC key generation on first
  /// use. Returns true if a wallet was created, false if one was already usable here.
  ///
  /// A newly-provisioned Portal client has no wallet, and nothing in the Rain surface creates
  /// one — every address lookup would fail with `walletUnavailable` until this runs.
  @discardableResult
  func ensurePortalWallet() async throws -> Bool {
    guard let portal = portalBox.value else { throw RainError.sdkNotInitialized }

    // Two independent facts: the signing share lives in this device's keychain, the wallet
    // itself lives on the Portal client. Creating on a client that already has one fails.
    let onDevice = try await portal.isWalletOnDevice()
    let onClient = try await portal.doesWalletExist()
    SampleLog.d("Portal.wallet", "ensurePortalWallet onDevice=\(onDevice) onClient=\(onClient)")

    if onDevice { return false }
    if onClient { throw PortalWalletSetupError.walletNotOnThisDevice }

    let created = try await portal.createWallet { status in
      SampleLog.d("Portal.wallet", "keygen status=\(status.status)")
    }
    SampleLog.i("Portal.wallet", "created wallet eth=\(created.ethereum)")
    return true
  }

  /// Builds the SDK with the Turnkey provider and resolves the Turnkey-backed client.
  func initializeTurnkey(
    turnkey: TurnkeyContext,
    walletAddress: String? = nil,
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) async throws {
    RainLogger.isEnabled = true
    closeActiveProvider()
    let provider = TurnkeyProvider(
      TurnkeyConfig(
        turnkey: turnkey,
        walletAddress: walletAddress,
        onSessionExpired: onSessionExpired
      )
    )
    let sdk = try builder(networkConfigs: WalletChain.networkConfigs)
      .register(provider)
      .build()
    try await resolve(sdk: sdk, providerId: .turnkey, provider: .turnkey)
    bind(.turnkey(provider), states: provider.sessionState.map(\.status))
  }

  /// The Rain wallet provider, created by ``prepareRainWallet(onSessionExpired:)``.
  /// Authentication (`sendLoginCode` / `confirmLoginCode`) runs on it before Rain is initialized.
  private(set) var rainWalletProvider: RainWallet.RainProvider?

  /// Creates the Rain wallet provider. The SDK embeds the backend identity and owns the code
  /// login flow; the host supplies the Rain environment and a way to obtain wallet auth tokens.
  ///
  /// The token provider here calls Rain's `/auth-tokens` with the Api-Key entered on the Home
  /// screen — DEMO ONLY. In a real app that call runs on your backend and this closure fetches
  /// the token from there. Without Rain API credentials the code flows throw `invalidConfig`;
  /// passkey login still works.
  @discardableResult
  func prepareRainWallet(
    passkeyDomain: String? = "passkeys.uptop.xyz",
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) -> RainWallet.RainProvider {
    RainLogger.isEnabled = true
    let rainApi = self.rainApi
    let provider = RainWallet.RainProvider(
      RainWalletConfig(
        environment: SampleEnvironment.rainApi == .sandbox ? .sandbox : .production,
        authTokenProvider: rainApi.map { api in
          { contact in try await api.mintWalletAuthToken(contact: contact) }
        },
        passkeyDomain: passkeyDomain,
        onSessionExpired: onSessionExpired
      )
    )
    rainWalletProvider = provider
    return provider
  }

  /// Builds the SDK with the prepared (and authenticated) Rain wallet provider and resolves the
  /// Rain-backed client.
  func initializeRainWallet() async throws {
    guard let provider = rainWalletProvider else {
      throw RainError.invalidConfig(details: "Call prepareRainWallet before initializeRainWallet")
    }
    closeActiveProvider()
    let sdk = try builder(networkConfigs: WalletChain.networkConfigs)
      .register(provider)
      .build()
    try await resolve(sdk: sdk, providerId: .rain, provider: .rainWallet)
    bind(.rainWallet(provider), states: provider.sessionState.map(\.status))
  }

  /// Builds the SDK with the Privy provider and resolves the Privy-backed client.
  func initializePrivy(
    privy: any Privy,
    walletAddress: String? = nil,
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) async throws {
    RainLogger.isEnabled = true
    closeActiveProvider()
    let provider = PrivyProvider(
      PrivyConfig(
        privy: privy,
        walletAddress: walletAddress,
        onSessionExpired: onSessionExpired
      )
    )
    let sdk = try builder(networkConfigs: WalletChain.networkConfigs)
      .register(provider)
      .build()
    try await resolve(sdk: sdk, providerId: .privy, provider: .privy)
    bind(.privy(provider), states: provider.sessionState.map(\.status))
  }

  // MARK: - Session

  /// Forces a refresh on the active provider; `tokenExpired` means re-auth is required.
  func refreshSession() async throws {
    switch providerHandle {
    case .none:
      throw RainError.sdkNotInitialized
    case .turnkey(let provider):
      try await provider.refreshSession()
    case .privy(let provider):
      try await provider.refreshSession()
    case .portal(let provider):
      try await provider.refreshSession()
    case .rainWallet(let provider):
      try await provider.refreshSession()
    }
  }

  /// Portal only: installs a host-minted token for the same Portal client.
  func updatePortalSessionToken(_ sessionToken: String) async throws {
    guard case .portal(let provider) = providerHandle else {
      throw RainError.sdkNotInitialized
    }
    try await provider.updateSessionToken(sessionToken)
  }

  /// Owns the resolved provider and mirrors its session state onto the main thread.
  private func bind<P: Publisher>(_ handle: ProviderHandle, states: P)
  where P.Output == WalletSessionStatus, P.Failure == Never {
    providerHandle = handle
    sessionSubscription = states
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in self?.sessionStatus = status }
  }

  /// A discarded provider must never fire its hooks.
  private func closeActiveProvider() {
    sessionSubscription = nil
    sessionStatus = nil
    providerHandle?.close()
    providerHandle = nil
  }

  /// The built registry, or throws `sdkNotInitialized` if no `initialize*` has run.
  func requireRain() throws -> RainSdk {
    guard let rain else { throw RainError.sdkNotInitialized }
    return rain
  }

  /// The resolved provider client, or throws `sdkNotInitialized` before initialization.
  func requireClient() throws -> RainClient {
    guard let client else { throw RainError.sdkNotInitialized }
    return client
  }

  /// Drops the built registry and resolved client.
  func reset() {
    closeActiveProvider()
    client?.reset()
    rain?.reset()
    rain = nil
    client = nil
    portalBox.value = nil
    isInitialized = false
    activeProvider = .none
  }

  // MARK: - Building

  /// Shared builder setup: RPC endpoints, token naming, and the Auth Pull targets.
  ///
  /// The testnet tokens this demo expects are registered here, the same mechanism host apps
  /// use (see `demoTokens`).
  private func builder(networkConfigs: [NetworkConfig]) -> RainSdk.Builder {
    RainSdk.builder()
      .rpcEndpoints(networkConfigs)
      .registerTokens(Self.demoTokens)
      // Auth Pull stays disabled until the trusted operator and token targets are supplied; the
      // config's kind (sandbox/production) is what ties it to the Rain environment.
      .authPullConfig(SampleEnvironment.authPullConfig)
  }

  private func resolve(sdk: RainSdk, providerId: ProviderId, provider: ActiveProvider) async throws {
    let resolved = try await sdk.provider(providerId)
    rain = sdk
    client = resolved
    isInitialized = resolved.isInitialized
    activeProvider = provider
  }
}
