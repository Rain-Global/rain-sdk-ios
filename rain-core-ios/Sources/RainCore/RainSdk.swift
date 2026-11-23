import Foundation
import Web3

/// Entry point and provider registry for the Rain SDK.
///
/// Built via ``RainSdk/builder()``: register RPC endpoints, one or more provider descriptors, and
/// optional tokens, then `build()`. Resolve a wallet-bound ``RainClient`` by id (`provider(_:)`)
/// or by capability (`first { }`). The registry is designed for the multi-provider case; a
/// single-provider app is simply the trivial `N = 1` instance of it.
///
/// Wallet-agnostic building (EIP-712 message, withdraw calldata, transaction parameters) is
/// available directly off `RainSdk` with no provider resolved.
public final class RainSdk: @unchecked Sendable {
  private let networkConfigs: [NetworkConfig]
  private let rpcEndpoints: [Int: String]
  private let descriptors: [ProviderId: ProviderDescriptor]
  private let registrationOrder: [ProviderId]

  // Shared, vendor-free infrastructure, built once and reused across every resolved provider.
  private let transactionBuilder: TransactionBuilderService
  private let tokenStore: TokenMetadataStore
  private let evmChainReader: EVMChainReader
  private let providerContext: ProviderContext

  /// Auth Pull targets for this instance, handed to every resolved client so an approval cannot
  /// target another environment's chains or another token.
  ///
  /// Narrowed to chains that actually have an RPC endpoint: the allowance read and the approval
  /// both go out over `rpcEndpoints`, so a configured chain with no endpoint could never work.
  private let authPullTokenAddresses: [Int: String]

  /// The chains Auth Pull is actually enabled on for *this* instance — the configured
  /// ``RainAuthPullConfig``'s chains intersected with the chains that have an RPC endpoint. Empty
  /// when no ``Builder/authPullConfig(_:)`` was supplied.
  ///
  /// This, not ``RainAuthPullChains/sandbox`` / ``RainAuthPullChains/production``, is what the
  /// approval guard enforces. Gate host UI on it: the static sets answer for an environment, this
  /// answers for the SDK the host built, and the two differ whenever a config is narrower than its
  /// environment or an RPC endpoint is missing.
  public let authPullChainIds: Set<Int>

  // Resolved clients are cached by provider id (lazy, resolved-once). We cache the *in-flight
  // resolution Task*, not the finished client, so concurrent first-resolutions of the same id
  // share one Task and `create(context:)` runs exactly once. Boxed in a class so we can identity-
  // compare on failure eviction.
  private final class ResolveBox {
    let task: Task<RainClient, Error>
    init(_ task: Task<RainClient, Error>) { self.task = task }
  }
  private var resolveBoxes: [ProviderId: ResolveBox] = [:]
  private let clientsLock = NSLock()
  /// Set once by ``close()``; guarded by `clientsLock`.
  private var isClosed = false

  /// Throws `sdkNotInitialized` after ``close()``: a closed registry hands out nothing.
  private func requireOpen() throws {
    if clientsLock.withLock({ isClosed }) { throw RainError.sdkNotInitialized }
  }

  fileprivate init(
    networkConfigs: [NetworkConfig],
    descriptors: [ProviderId: ProviderDescriptor],
    registrationOrder: [ProviderId],
    registeredTokens: [TokenInfo],
    authPullConfig: RainAuthPullConfig?
  ) {
    self.networkConfigs = networkConfigs
    self.descriptors = descriptors
    self.registrationOrder = registrationOrder

    var endpoints: [Int: String] = [:]
    for config in networkConfigs { endpoints[config.chainId] = config.rpcUrl }
    self.rpcEndpoints = endpoints

    let reader = EVMChainReader(networkConfigs: networkConfigs)
    let store = TokenMetadataStore(chainReader: reader, seedTokens: registeredTokens)
    let builder = TransactionBuilderService(networkConfigs: networkConfigs)
    self.evmChainReader = reader
    self.tokenStore = store
    self.transactionBuilder = builder
    self.providerContext = ProviderContext(
      rpcEndpoints: endpoints,
      networkConfigs: networkConfigs,
      tokenStore: store,
      transactionBuilder: builder,
      evmChainReader: reader
    )

    let trustedTokens = (authPullConfig?.tokenAddresses ?? [:])
      .filter { endpoints[$0.key] != nil }
    self.authPullTokenAddresses = trustedTokens
    self.authPullChainIds = Set(trustedTokens.keys)
  }

  // MARK: - Registry introspection

  /// The set of registered provider ids.
  public var providerIds: Set<ProviderId> { Set(descriptors.keys) }

  /// All registered provider descriptors, in registration order.
  public var providers: [any ProviderDescriptor] { registrationOrder.compactMap { descriptors[$0] } }

  // MARK: - Resolution

  /// Resolves (and caches) the wallet-bound ``RainClient`` for the given provider id.
  /// Suspends because `create(context:)` may materialize / probe the vendor wallet on first access.
  ///
  /// - Throws: `RainError.providerNotRegistered` if no provider is registered under `id`.
  public func provider(_ id: ProviderId) async throws -> RainClient {
    try requireOpen()
    guard descriptors[id] != nil else {
      throw RainError.providerNotRegistered(details: "No provider registered for id '\(id.rawValue)'")
    }

    // Get-or-create the shared resolution Task under the lock — the only critical section. The
    // first caller installs the Task; concurrent callers find and await the same one, so
    // `create(context:)` (and its side effects) fire once.
    let box: ResolveBox = {
      clientsLock.lock(); defer { clientsLock.unlock() }
      if let existing = resolveBoxes[id] { return existing }
      let task = Task<RainClient, Error> { [self] in
        let descriptor = descriptors[id]!
        let walletProvider: any WalletProvider
        do {
          walletProvider = try await descriptor.create(context: providerContext)
        } catch {
          throw RainError.from(underlying: error)
        }
        return RainSdkManager(
          walletProvider: walletProvider,
          networkConfigs: networkConfigs,
          transactionBuilder: transactionBuilder,
          tokenStore: tokenStore,
          providerId: descriptor.id,
          capabilities: descriptor.capabilities,
          chainReader: evmChainReader,
          authPullChainIds: authPullChainIds,
          authPullTokenAddresses: authPullTokenAddresses
        )
      }
      let newBox = ResolveBox(task)
      resolveBoxes[id] = newBox
      return newBox
    }()

    do {
      return try await box.task.value
    } catch {
      // Failed resolution isn't cached — evict so a later call can retry. Only clear if the stored
      // box is still ours; a concurrent retry may already have installed a fresh one.
      clientsLock.withLock {
        if resolveBoxes[id] === box { resolveBoxes[id] = nil }
      }
      throw error
    }
  }

  /// Tears down all resolved clients. Idempotent.
  ///
  /// The configuration (network configs, descriptors, token store) is immutable state fixed at
  /// `build()`, so this instance stays usable: the next `provider(_:)` / `first(where:)` call
  /// re-resolves the provider from scratch (re-running `create(context:)`). Build a new `RainSdk`
  /// via ``builder()`` to change configuration.
  public func reset() {
    let boxes: [ResolveBox] = clientsLock.withLock {
      let values = Array(resolveBoxes.values)
      resolveBoxes.removeAll()
      return values
    }
    // Reset each resolved client, and cancel in-flight resolutions so they don't finish
    // into an evicted slot.
    for box in boxes {
      let task = box.task
      task.cancel()
      Task {
        if let client = try? await task.value { client.reset() }
      }
    }
    RainLogger.info("Rain SDK: Reset (resolved clients evicted)")
  }

  /// Full teardown: ``reset()``, then ``ProviderDescriptor/close()`` on every registered
  /// descriptor so vendor clients and session watchers stop and no `onSessionExpired` hook can
  /// fire again. Idempotent.
  ///
  /// Terminal, unlike ``reset()``: ``provider(_:)``, ``first(where:)``, ``tokenMetadata(chainId:address:)``
  /// and ``registerTokens(_:)`` throw `RainError.sdkNotInitialized` afterwards. Build a new
  /// `RainSdk` via ``builder()`` for the next login. Same contract as the Android SDK.
  public func close() {
    clientsLock.withLock { isClosed = true }
    reset()
    for descriptor in providers { descriptor.close() }
    RainLogger.info("Rain SDK: Closed (providers torn down)")
  }

  /// Resolves the first registered provider (in registration order) matching `predicate`, e.g.
  /// `rain.first { $0.capabilities.contains(.export) }`.
  ///
  /// - Throws: `RainError.providerNotRegistered` if no registered provider matches.
  public func first(where predicate: (any ProviderDescriptor) -> Bool) async throws -> RainClient {
    try requireOpen()
    for id in registrationOrder {
      guard let descriptor = descriptors[id] else { continue }
      if predicate(descriptor) {
        return try await provider(id)
      }
    }
    throw RainError.providerNotRegistered(details: "No registered provider matches the requested capability")
  }

  // MARK: - Wallet-agnostic transaction building

  /// Reads the collateral's current admin nonce — the value `buildEIP712Message` binds when
  /// `nonce` is omitted.
  public func getLatestNonce(chainId: Int, proxyAddress: String) async throws -> BigUInt {
    try await transactionBuilder.getLatestNonce(proxyAddress: proxyAddress, chainId: chainId)
  }

  /// Whether `walletAddress` is an admin of the collateral at `proxyAddress`.
  ///
  /// - Returns: The contract's answer, or `nil` when the check could not run (an RPC failure, or
  ///   a collateral exposing no `isAdmin`). A `nil` means unknown: a withdrawal proceeds on it, a
  ///   non-zero Auth Pull approval is refused.
  public func isCollateralAdmin(
    chainId: Int,
    proxyAddress: String,
    walletAddress: String
  ) async -> Bool? {
    let check = try? await transactionBuilder.isCollateralAdmin(
      proxyAddress: proxyAddress,
      walletAddress: walletAddress,
      chainId: chainId
    )
    switch check {
    case .admin: return true
    case .notAdmin: return false
    case .failed, .notCollateral, nil: return nil
    }
  }

  /// Builds the EIP-712 message the wallet signs to authorize a withdrawal, along with the salt
  /// bound into it. Pass `nonce: nil` to read the collateral's current nonce on chain.
  public func buildEIP712Message(
    chainId: Int,
    walletAddress: String,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    nonce: BigUInt? = nil
  ) async throws -> RainEIP712Message {
    try await WithdrawalBuilder.buildEIP712Message(
      builder: transactionBuilder,
      chainId: chainId,
      walletAddress: walletAddress,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      nonce: nonce
    )
  }

  /// ABI-encodes the `withdrawAsset` call for the collateral controller.
  ///
  /// Pure encoding — no RPC, so it needs no chain id.
  ///
  /// - Parameters:
  ///   - executorSignature: Rain's authorization for this withdrawal, obtained by the host from
  ///     the Rain API (`GET /v1/issuing/users/{userId}/signatures/withdrawals`).
  ///   - walletSalt: The salt from ``RainEIP712Message/salt``, unchanged.
  ///   - walletSignature: The wallet's hex signature over ``RainEIP712Message/message``.
  public func buildWithdrawTransactionData(
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    executorSignature: RainAdminSignature,
    walletSalt: Data,
    walletSignature: String
  ) throws -> String {
    try WithdrawalBuilder.buildWithdrawTransactionData(
      builder: transactionBuilder,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      executorSignature: executorSignature,
      walletSalt: walletSalt,
      walletSignature: walletSignature
    )
  }

  /// Composes Rain-owned transaction parameters. Rain-owned so the public surface does not leak
  /// Portal/Turnkey types.
  public func buildTransactionParameters(
    walletAddress: String,
    contractAddress: String,
    transactionData: String
  ) -> RainTransactionParameters {
    RainTransactionParameters(
      from: walletAddress,
      to: contractAddress,
      value: 0.ethToWei.toHexString,
      data: transactionData
    )
  }

  /// Registers additional tokens so their metadata resolves without an on-chain lookup. Entries
  /// are stored before this returns, so a register-then-query is ordered. The whole list is
  /// validated first — address well-formed for its chain family (EIP-55 checksum when
  /// mixed-case; base58 32 bytes on Solana), decimals in 0...77 — and one bad entry registers
  /// nothing.
  ///
  /// - Throws: `RainError.invalidConfig` on a malformed entry; `sdkNotInitialized` after ``close()``.
  public func registerTokens(_ tokens: [TokenInfo]) async throws {
    try requireOpen()
    try await tokenStore.register(tokens)
  }

  /// Metadata (symbol, name, decimals) for a contract token the host knows only by address —
  /// typically the tokens listed in a Rain collateral contract. Resolution order: the built-in
  /// registry, host-registered tokens, then on-chain `decimals()` / `symbol()` / `name()` reads
  /// over the configured RPC (cached once decimals resolve). Needs no wallet provider.
  ///
  /// Returns `nil` only when decimals could not be established (RPC failure, unknown SPL mint)
  /// — never a guessed default, since wrong decimals would scale a withdrawal or approval amount
  /// by orders of magnitude. `symbol` and `name` inside a non-nil result may still be nil if
  /// those reads failed. Solana chains resolve from the registry and host-registered tokens only.
  ///
  /// - Throws: `RainError.invalidConfig` for a chain with no RPC endpoint, a malformed `address`
  ///   (EVM: `0x` + 40 hex, EIP-55 checksum when mixed-case; Solana: base58 32 bytes), or an
  ///   on-chain `decimals()` outside 0...77; `sdkNotInitialized` after ``close()``. Same contract
  ///   as the Android SDK.
  public func tokenMetadata(chainId: Int, address: String) async throws -> TokenInfo? {
    try requireOpen()
    guard rpcEndpoints[chainId] != nil else {
      throw RainError.invalidConfig(details: "No RPC endpoint configured for chainId=\(chainId)")
    }
    try TokenInfoValidation.requireValidAddress(chainId: chainId, address: address)
    return try await tokenStore.resolvedTokenInfo(chainId: chainId, address: address)
  }

  static func parseISO8601(_ string: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) { return date }
    return ISO8601DateFormatter().date(from: string)
  }

  // MARK: - Builder

  /// Returns a new builder. Register RPC endpoints and provider descriptors, then `build()`.
  public static func builder() -> Builder { Builder() }

  /// Fluent builder for `RainSdk`.
  public final class Builder {
    private var networkConfigs: [NetworkConfig] = []
    private var descriptors: [ProviderId: ProviderDescriptor] = [:]
    private var registrationOrder: [ProviderId] = []
    /// Descriptors displaced by a later `register` of the same id; closed by `build()` once the
    /// registry is valid, so a replaced provider's session watcher does not outlive the registry
    /// and a failed build leaves the host's objects untouched.
    private var replaced: [any ProviderDescriptor] = []
    private var registeredTokens: [TokenInfo] = []
    private var authPullConfig: RainAuthPullConfig?

    public init() {}

    /// Sets the network configurations (chain id + RPC URL). Required.
    @discardableResult
    public func rpcEndpoints(_ configs: [NetworkConfig]) -> Builder {
      networkConfigs = configs
      return self
    }

    /// Sets RPC endpoints from a `[chainId: rpcUrl]` map.
    @discardableResult
    public func rpcEndpoints(_ map: [Int: String]) -> Builder {
      networkConfigs = map.map { NetworkConfig(chainId: $0.key, rpcUrl: $0.value) }
      return self
    }

    /// Registers a provider descriptor, keyed by its `id`. Re-registering an id replaces the
    /// prior descriptor, and `build()` closes the replaced one (see ``ProviderDescriptor/close()``).
    /// Registering a copy of the descriptor already held under that id is a no-op — descriptors
    /// are values, so a copy shares the live one's internals and must not be closed.
    @discardableResult
    public func register(_ provider: any ProviderDescriptor) -> Builder {
      if let previous = descriptors[provider.id] {
        if !Self.isSameDescriptor(previous, provider) { replaced.append(previous) }
      } else {
        registrationOrder.append(provider.id)
      }
      descriptors[provider.id] = provider
      return self
    }

    /// Descriptors are structs, so "the same descriptor" means copies of one value: the same
    /// concrete type whose class-typed stored properties (coordinator, context, controller…) are
    /// the very same instances. Two separately constructed descriptors, even with equal configs,
    /// hold different instances. A descriptor with no class-typed properties has nothing shared
    /// to protect, so it is never treated as a copy.
    private static func isSameDescriptor(_ a: any ProviderDescriptor, _ b: any ProviderDescriptor) -> Bool {
      guard type(of: a) == type(of: b) else { return false }
      let lhs = referenceIdentities(of: a), rhs = referenceIdentities(of: b)
      return !lhs.isEmpty && lhs == rhs
    }

    private static func referenceIdentities(of value: Any) -> [ObjectIdentifier] {
      Mirror(reflecting: value).children.compactMap { child in
        type(of: child.value) is AnyClass ? ObjectIdentifier(child.value as AnyObject) : nil
      }
    }

    /// Seeds the token store with token metadata. Validated at `build()` like every other
    /// register path — a malformed entry fails the build with `invalidConfig`.
    @discardableResult
    public func registerTokens(_ tokens: [TokenInfo]) -> Builder {
      registeredTokens.append(contentsOf: tokens)
      return self
    }

    /// Enables Auth Pull for the exact token contracts in `config`. Without this
    /// call, approval, allowance read, confirmation, and approval-fee methods fail closed.
    @discardableResult
    public func authPullConfig(_ config: RainAuthPullConfig) -> Builder {
      authPullConfig = config
      return self
    }

    /// Validates configuration and builds the `RainSdk`.
    ///
    /// At least one RPC endpoint is required. Providers are optional: building with none yields a
    /// **wallet-agnostic** `RainSdk` — the transaction-building methods (`buildEIP712Message`,
    /// `buildWithdrawTransactionData`, `buildTransactionParameters`) work, while `provider(_:)` /
    /// `first(where:)` will throw until a provider is registered.
    /// - Throws: `RainError.invalidConfig` if no/invalid RPC endpoints were provided.
    public func build() throws -> RainSdk {
      guard !networkConfigs.isEmpty else {
        throw RainError.invalidConfig(details: "At least one RPC endpoint is required")
      }
      for config in networkConfigs {
        guard config.chainId > 0 else {
          throw RainError.invalidConfig(
            details: "Invalid RPC endpoint for chainId \(config.chainId): \(config.rpcUrl)"
          )
        }
        guard config.rpcUrl.isValidHTTPURL() else {
          throw RainError.invalidConfig(
            details: "Invalid RPC URL for chainId \(config.chainId), an https URL is required: \(config.rpcUrl)"
          )
        }
      }
      try TokenInfoValidation.requireValid(registeredTokens)
      try validateAuthPullConfig()
      // The Rain wallet and the Turnkey provider share one process-wide backend context, so an
      // app can use one or the other — never both at once.
      if descriptors[.rain] != nil, descriptors[.turnkey] != nil {
        throw RainError.invalidConfig(
          details: "The Rain wallet provider and the Turnkey provider cannot both be registered; "
            + "they share one process-wide wallet backend"
        )
      }
      // Ownership moves here: descriptors replaced during registration are closed only once the
      // registry is valid, so a throwing build leaves the host's objects untouched.
      for descriptor in replaced { descriptor.close() }
      replaced.removeAll()
      return RainSdk(
        networkConfigs: networkConfigs,
        descriptors: descriptors,
        registrationOrder: registrationOrder,
        registeredTokens: registeredTokens,
        authPullConfig: authPullConfig
      )
    }

    /// Rejects an Auth Pull configuration that cannot be the one Rain uses: a malformed or zero
    /// token, an empty target set, a chain outside the Auth Pull set its kind names, or no RPC
    /// endpoint for any configured chain.
    private func validateAuthPullConfig() throws {
      guard let config = authPullConfig else { return }

      guard !config.tokenAddresses.isEmpty else {
        throw RainError.invalidConfig(
          details: "Auth Pull must configure at least one token contract"
        )
      }

      // The config's kind names the environment its tokens belong to; its chains must
      // come from that environment's Auth Pull set. A custom config can front either environment,
      // so its chains are checked against both known sets.
      let allowedChains = RainAuthPullChains.supported(for: config.kind)
      let unexpected = Set(config.tokenAddresses.keys).subtracting(allowedChains)
      guard unexpected.isEmpty else {
        throw RainError.invalidConfig(
          details: """
            Auth Pull chains \(unexpected.sorted()) are not Auth Pull chains for this configuration's environment
            """
        )
      }

      for (chainId, address) in config.tokenAddresses {
        guard address.isValidEthereumAddress, !address.isZeroAddress
        else {
          throw RainError.invalidConfig(
            details: "Invalid Auth Pull token contract for chainId=\(chainId): \(address)"
          )
        }
      }

      let configuredChains = Set(networkConfigs.map(\.chainId))
      guard !configuredChains.isDisjoint(with: config.tokenAddresses.keys) else {
        throw RainError.invalidConfig(
          details: "No RPC endpoint configured for any trusted Auth Pull chain"
        )
      }
    }
  }
}
