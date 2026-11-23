import Combine
import Foundation
import PrivySDK
import RainCore

/// Configuration for the Privy provider.
///
/// Privy authentication and `PrivySdk.initialize(...)` happen outside Rain via the Privy iOS SDK:
/// initialize the `Privy` singleton at app start, log the user in, ensure an embedded Ethereum
/// wallet exists (`user.createEthereumWallet()`), then hand the singleton here.
public struct PrivyConfig: Sendable {
  /// The initialized, authenticated Privy singleton.
  public let privy: any Privy

  /// Optional explicit embedded-wallet address; when `nil` Rain uses the user's first embedded
  /// Ethereum wallet.
  public let walletAddress: String?

  /// Auth-guard and transient-retry behavior for every wallet call.
  public let sessionPolicy: PrivySessionPolicy

  /// Re-auth hook: invoked once per session death when the Privy session dies — whether that
  /// is discovered during a wallet call or by the passive session watcher. Not necessarily on
  /// the main thread; hop to the main actor before touching UI, and never call back into the
  /// SDK synchronously from it. Restart authentication from here.
  public let onSessionExpired: (@Sendable () -> Void)?

  public init(
    privy: any Privy,
    walletAddress: String? = nil,
    sessionPolicy: PrivySessionPolicy = PrivySessionPolicy(),
    onSessionExpired: (@Sendable () -> Void)? = nil
  ) {
    self.privy = privy
    self.walletAddress = walletAddress
    self.sessionPolicy = sessionPolicy
    self.onSessionExpired = onSessionExpired
  }
}

/// Privy adapter — the registrable ``ProviderDescriptor`` for Privy's embedded-key signer.
///
/// Custody (signing, broadcasting) routes through Privy's EIP-1193 embedded-wallet provider;
/// balance / fee reads use Rain's configured RPC via ``PrivyRpcClient``.
///
/// On Solana: register the cluster's RPC URL and create an embedded Solana wallet
/// (`user.createSolanaWallet()`); `getAddress`, `getBalance`, native SOL and SPL token sends
/// resolve against that account. Fee estimates and typed-data stay EVM-only, and an embedded
/// Ethereum wallet is always required.
///
/// ```swift
/// import RainCore
/// import RainPrivy
///
/// let privy = PrivySdk.initialize(config: PrivyConfig(appId: "…", appClientId: "…"))
/// // …authenticate the user and ensure an embedded Ethereum wallet exists…
/// let rain = try RainSdk.builder()
///     .rpcEndpoints([43114: "https://…"])
///     .register(PrivyProvider(PrivyConfig(privy: privy)))
///     .build()
/// let client = try await rain.provider(.privy)
/// ```
public struct PrivyProvider: ProviderDescriptor {
  private let config: PrivyConfig
  private let coordinator: PrivySessionCoordinator

  public init(_ config: PrivyConfig) {
    self.config = config
    // Stores references only — the vendor singleton is not touched until `create`, so a
    // provider built purely to read `id`/`capabilities` stays inert.
    self.coordinator = PrivySessionCoordinator(
      auth: LivePrivyAuthSource(privy: config.privy),
      policy: config.sessionPolicy,
      onSessionExpired: config.onSessionExpired
    )
    // Register Privy's error mapping with core once, so Privy vendor errors classify into
    // RainError cases without RainCore importing PrivySDK.
    PrivyErrorMapping.registerOnce()
  }

  public var id: ProviderId { .privy }

  /// Privy holds an exportable embedded key with a recovery flow, over EVM and Solana.
  public var capabilities: Set<Capability> { [.export, .recovery, .multiChain] }

  /// The Privy session as seen at the Rain boundary, over time. Emits on every Privy
  /// auth-state change, so a host can react to a session dying silently without waiting for a
  /// wallet call to fail.
  public var sessionState: AnyPublisher<PrivySessionState, Never> {
    coordinator.sessionStates
  }

  /// Snapshot of `sessionState` right now.
  public func currentSessionState() -> PrivySessionState {
    coordinator.currentState()
  }

  /// Forces a Privy session refresh (`PrivyUser.refresh`). Rarely needed — Privy refreshes
  /// its own session before every call — but available for hosts that want an explicit health
  /// check. Throws `RainError.tokenExpired` when the session cannot be refreshed — the
  /// host must re-authenticate.
  public func refreshSession() async throws {
    try await coordinator.refreshNow()
  }

  /// Stops the passive session watcher. Call when discarding this provider (e.g. rebuilding
  /// the SDK for a new login) so a stale provider stops observing the process-wide Privy
  /// singleton and can never fire its expiry hook again.
  public func close() {
    coordinator.stopMonitoring()
  }

  public func create(context: ProviderContext) async throws -> any WalletProvider {
    // Always watch: beyond the optional host hook, the watcher drives cached-account eviction
    // on session death so a re-login can never sign with the previous user's accounts.
    coordinator.startMonitoring()

    let manager = PrivyManager(privy: config.privy, sessions: coordinator)
    coordinator.onSessionDeath {
      Task { await manager.evictCachedAccounts() }
    }

    let provider = PrivyWalletProvider(
      manager: manager,
      rpcEndpoints: context.rpcEndpoints,
      tokenStore: context.tokenStore,
      solanaSupport: context.solanaSupport,
      walletAddressOverride: config.walletAddress
    )

    // Probe — ensures Privy has an embedded Ethereum wallet available before handing it out.
    do {
      _ = try await provider.address()
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

    RainLogger.info("Rain SDK: Registered Privy instance with \(context.networkConfigs.count) network(s)")
    return provider
  }
}
