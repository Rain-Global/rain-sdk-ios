import Combine
import Foundation
import PortalSwift
import RainCore

/// Configuration for the Portal provider.
public struct PortalConfig: @unchecked Sendable {
  /// A valid Portal session token.
  public let sessionToken: String

  /// Refresh, auth-guard and transient-retry behavior for every wallet call.
  public let sessionPolicy: PortalSessionPolicy

  /// Called when Portal rejects the token: return a fresh token for the SAME Portal client (the
  /// SDK rebuilds the client and retries once), or `nil` to decline. Runs in the refresh slot —
  /// never call back into this provider from it.
  public let onSessionTokenNeeded: (@Sendable () async throws -> String?)?

  /// Fired once per session death when no fresh token could be installed. Not on the main
  /// actor; restart authentication from here.
  public let onSessionExpired: (@Sendable () -> Void)?

  public init(
    sessionToken: String,
    sessionPolicy: PortalSessionPolicy = PortalSessionPolicy(),
    onSessionTokenNeeded: (@Sendable () async throws -> String?)? = nil,
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) {
    self.sessionToken = sessionToken
    self.sessionPolicy = sessionPolicy
    self.onSessionTokenNeeded = onSessionTokenNeeded
    self.onSessionExpired = onSessionExpired
  }
}

/// Registrable descriptor for the Portal MPC wallet provider. Lives in the `RainPortal` module so
/// a Portal-only client never resolves Turnkey or Privy.
///
/// ```swift
/// import RainCore
/// import RainPortal
///
/// let rain = try RainSdk.builder()
///     .rpcEndpoints([43114: "https://…"])
///     .register(PortalProvider(PortalConfig(sessionToken: "<token>")))
///     .build()
/// let client = try await rain.provider(.portal)
/// ```
public struct PortalProvider: ProviderDescriptor {
  /// Builds a vendor client for a token and RPC config; concrete `Portal` in production.
  internal typealias PortalFactory =
    @Sendable (_ sessionToken: String, _ rpcConfig: [String: String]) throws -> PortalRequestProtocol

  /// Mutable resolution state behind the value-typed descriptor; set once in `create`.
  private final class ResolutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: PortalClientHandle?
    private var rpcConfig: [String: String] = [:]

    func bind(handle: PortalClientHandle, rpcConfig: [String: String]) {
      lock.withLock {
        self.handle = handle
        self.rpcConfig = rpcConfig
      }
    }

    func resolved() -> (PortalClientHandle, [String: String])? {
      lock.withLock { handle.map { ($0, rpcConfig) } }
    }
  }

  private let config: PortalConfig
  private let onPortalCreated: (@Sendable (Portal) -> Void)?
  private let portalFactory: PortalFactory
  private let state = ResolutionState()
  private let coordinator: PortalSessionCoordinator

  /// - Parameters:
  ///   - config: Portal configuration (session token, session policy and hooks).
  ///   - onPortalCreated: Optional hook invoked with the underlying `Portal` instance once it's
  ///     constructed during resolution. Lets a host reach Portal-specific APIs not on the Rain
  ///     port (e.g. `recoverWallet`, `backupWallet`) without core exposing PortalSwift types.
  ///     Re-invoked after every session-token refresh, because the refresh rebuilds the client.
  public init(_ config: PortalConfig, onPortalCreated: (@Sendable (Portal) -> Void)? = nil) {
    self.init(config, onPortalCreated: onPortalCreated, portalFactory: Self.livePortalFactory)
  }

  internal init(
    _ config: PortalConfig,
    onPortalCreated: (@Sendable (Portal) -> Void)?,
    portalFactory: @escaping PortalFactory
  ) {
    self.config = config
    self.onPortalCreated = onPortalCreated
    self.portalFactory = portalFactory
    let state = self.state
    self.coordinator = PortalSessionCoordinator(
      policy: config.sessionPolicy,
      onSessionTokenNeeded: config.onSessionTokenNeeded,
      onSessionExpired: config.onSessionExpired,
      installToken: { token in
        guard let (handle, rpcConfig) = state.resolved() else {
          throw RainError.sdkNotInitialized
        }
        let rebuilt = try portalFactory(token, rpcConfig)
        handle.replace(with: rebuilt)
        if let portal = rebuilt as? Portal { onPortalCreated?(portal) }
      }
    )
    // Register Portal's error mapping with core once, so Portal vendor errors classify correctly
    // without RainCore importing PortalSwift.
    PortalErrorMapping.registerOnce()
  }

  public var id: ProviderId { .portal }

  public var capabilities: Set<Capability> { [.export, .recovery] }

  /// The session over time, driven by call outcomes and refreshes (Portal has no auth state).
  public var sessionState: AnyPublisher<PortalSessionState, Never> {
    coordinator.sessionStates
  }

  /// Snapshot of `sessionState` right now.
  public func currentSessionState() -> PortalSessionState {
    coordinator.currentState()
  }

  /// Re-mints via `onSessionTokenNeeded` and rebuilds the client; `.tokenExpired` on failure.
  public func refreshSession() async throws {
    guard state.resolved() != nil else { throw RainError.sdkNotInitialized }
    try await coordinator.refreshNow()
  }

  /// Installs a host-minted token (same Portal client) and rebuilds the client around it.
  /// Throws `.invalidConfig` when the token cannot be installed; the current client stays live.
  public func updateSessionToken(_ sessionToken: String) async throws {
    guard state.resolved() != nil else { throw RainError.sdkNotInitialized }
    try await coordinator.installNow(sessionToken)
  }

  /// Silences the session hooks; call when discarding this provider.
  public func close() {
    coordinator.stop()
  }

  public func create(context: ProviderContext) async throws -> any WalletProvider {
    guard !config.sessionToken.isEmpty else {
      throw RainError.unauthorized(details: "Portal session token must not be empty")
    }

    // Configs are already validated by RainSdk.Builder.build(); just map to Portal's form.
    let rpcConfig = Self.portalRpcConfig(from: context.networkConfigs)

    do {
      let portal = try portalFactory(config.sessionToken, rpcConfig)
      let handle = PortalClientHandle(portal)
      state.bind(handle: handle, rpcConfig: rpcConfig)
      RainLogger.info("Rain SDK: Registered Portal instance with \(context.networkConfigs.count) network(s)")
      if let concrete = portal as? Portal { onPortalCreated?(concrete) }
      return PortalWalletProviderAdapter(
        handle: handle,
        tokenStore: context.tokenStore,
        sessions: coordinator
      )
    } catch let error as RainError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A cancelled URLSession call surfaces as a URL error, not CancellationError; the
      // caller walking away must never be reported as a network or provider verdict.
      if Task.isCancelled { throw CancellationError() }
      throw RainError.from(underlying: error)
    }
  }

  /// Maps network configs to Portal's `eip155:<chainId> → rpcUrl` RPC config form.
  static func portalRpcConfig(from configs: [NetworkConfig]) -> [String: String] {
    var rpcConfig: [String: String] = [:]
    for cfg in configs {
      rpcConfig["eip155:\(cfg.chainId)"] = cfg.rpcUrl
    }
    return rpcConfig
  }

  /// The production client builder; storage backends are fresh per build.
  private static let livePortalFactory: PortalFactory = { sessionToken, rpcConfig in
    try Portal(
      sessionToken,
      withRpcConfig: rpcConfig,
      autoApprove: true,
      featureFlags: FeatureFlags(isMultiBackupEnabled: true),
      iCloud: ICloudStorage(),
      keychain: PortalKeychain(),
      passwords: PasswordStorage()
    )
  }
}
