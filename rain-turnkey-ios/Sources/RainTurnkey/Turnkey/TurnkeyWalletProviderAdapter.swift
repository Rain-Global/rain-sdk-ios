import Foundation
import TurnkeyHttp
import TurnkeySwift
import TurnkeyTypes
import Web3
@_spi(RainAdapter) import RainCore

/// Turnkey-based implementation of `WalletProvider`.
/// Used when the SDK is initialized with `initializeTurnkey(...)`.
internal final class TurnkeyWalletProviderAdapter: WalletProvider, RainTypedDataSignerProvider, RainTransactionFeeEstimatingProvider, RainSolanaTransfersProvider, @unchecked Sendable {
  internal enum AdapterConstants {
    static let defaultNativeDecimals = 18
    static let defaultPollingAttempts = 30
    static let pollingIntervalNanoseconds: UInt64 = 1_000_000_000
    /// Turnkey returns a status id, not a Solana signature, so the signature is read back from
    /// the chain as a defensive fallback when the status response carries none.
    static let solanaSignatureLookupAttempts = 8
    /// Used when `eth_estimateGas` returns zero or an unparseable value for a plain transfer
    /// (no calldata) — the intrinsic transfer cost. Never applied to contract calls.
    static let fallbackGasLimit = 21_000
  }

  private struct ActivityDraft: Sendable {
    let id: String
    let timestamp: TimeInterval
    let from: String
    let to: String
    let value: String?
    let data: String?
    let chainId: Int
    let sendTransactionStatusId: String?
  }

  private let turnkey: TurnkeyContextProtocol
  /// Guards every Turnkey call: expiry check, proactive refresh, refresh-on-401, backoff.
  internal let sessions: TurnkeySessionCoordinator
  private let networkConfigsByChainId: [Int: NetworkConfig]
  private let walletAddressOverride: String?
  private let jsonRpcClient: JsonRpcClient
  private let chainReader: ChainReader
  private let solanaSupport: RainSolanaSupport
  private let tokenStore: TokenMetadataStore
  private let history: any TurnkeyHistoryProviding

  private var solanaChainReader: ChainReader { solanaSupport.chainReader }
  private var solanaRpcClient: SolanaRpcClient { solanaSupport.solanaRpcClient }
  private var solanaTransferComposer: SolanaTransferComposer { solanaSupport.transferComposer }

  /// Pause between status/signature polls. Overridable in tests so timeout paths finish fast.
  internal var pollingIntervalNanoseconds: UInt64 = AdapterConstants.pollingIntervalNanoseconds

  // Once resolved, each address is stable for the adapter's lifetime, so cache it. EVM and
  // Solana accounts are cached independently — a Solana request never reads the EVM address.
  // Resolution is single-flighted: concurrent first callers share one in-flight Task, so
  // `refreshWallets` runs at most once per resolution.
  private var cachedAddress: String?
  private var cachedSolanaAddress: String?
  private var addressResolution: Task<String, Error>?
  private var solanaAddressResolution: Task<String, Error>?
  /// Organization the cached addresses were resolved under. `TurnkeyContext` is a process-wide
  /// singleton with a logout path, so a host that re-authenticates as another user without
  /// rebuilding the SDK would otherwise keep reading — and sending from — the previous user's
  /// addresses.
  private var cachedSessionOrganizationId: String?
  private let cachedAddressLock = NSLock()

  /// Every send, transfer or raw, follows this flag; there is no per-call override. With it on,
  /// Turnkey's Gas Station builds and fee-covers the outer transaction (gasless for the user).
  /// Fee estimates still quote the on-chain cost, so hosts can show the saving. See
  /// `TurnkeyConfig.sponsorGas`.
  private let sponsorGas: Bool

  // MARK: - Send gating & sponsorship (WalletProvider hooks)

  /// Turnkey broadcasts on a fixed network set; core calls this before withdrawals and approvals,
  /// and every send entry here re-checks so no path reaches the vendor on an uncovered chain.
  public func requireSendSupport(chainId: Int) throws {
    try TurnkeyBroadcastChains.requireSendSupport(chainId: chainId)
  }

  /// Sponsorship applies exactly where Turnkey can broadcast; elsewhere the wallet pays.
  public func sponsorsFees(chainId: Int) -> Bool {
    sponsorGas && TurnkeyBroadcastChains.supportsSend(chainId: chainId)
  }

  /// The capabilities a Turnkey provider advertises for a given `sponsorGas` setting. Shared
  /// with `TurnkeyProvider` so the descriptor's set and the resolved wallet's set cannot drift.
  static func capabilities(sponsorGas: Bool) -> Set<Capability> {
    // `.export`: managed mode exports the seed phrase and per-account keys. NOT `.biometricGate`:
    // the vendor signs with a Secure Enclave key created under `SecureEnclaveConfig(authPolicy:
    // .none)` (swift-sdk 4.0.0 `SecureEnclaveStamper.createKeyPair()`), so nothing gates signing;
    // passkeys/biometrics only appear at login. Same set as the Android adapter.
    var set: Set<Capability> = [.export, .multiChain]
    if sponsorGas { set.insert(.gasSponsorship) }
    return set
  }

  /// Drops the cached addresses and in-flight resolutions when the Turnkey session's organization
  /// changes (logout, or re-auth as a different user). Callers must hold `cachedAddressLock`.
  private func evictAddressCachesIfSessionChanged() {
    let currentOrganizationId = turnkey.session?.organizationId
    guard currentOrganizationId != cachedSessionOrganizationId else { return }
    cachedSessionOrganizationId = currentOrganizationId
    cachedAddress = nil
    cachedSolanaAddress = nil
    addressResolution = nil
    solanaAddressResolution = nil
  }

  internal init(
    turnkey: TurnkeyContextProtocol,
    networkConfigs: [NetworkConfig],
    walletAddress: String? = nil,
    sponsorGas: Bool = true,
    jsonRpcClient: JsonRpcClient = JsonRpcClient(),
    chainReader: ChainReader,
    solanaSupport: RainSolanaSupport? = nil,
    tokenStore: TokenMetadataStore? = nil,
    history: (any TurnkeyHistoryProviding)? = nil,
    sessionCoordinator: TurnkeySessionCoordinator? = nil
  ) {
    self.turnkey = turnkey
    self.sessions = sessionCoordinator ?? TurnkeySessionCoordinator(turnkey: turnkey)
    self.networkConfigsByChainId = Dictionary(uniqueKeysWithValues: networkConfigs.map { ($0.chainId, $0) })
    self.walletAddressOverride = walletAddress
    self.sponsorGas = sponsorGas
    self.jsonRpcClient = jsonRpcClient
    // Required (no EVMChainReader fallback): that type is core-internal, and `TurnkeyProvider`
    // always hands in the shared reader from `ProviderContext`.
    self.chainReader = chainReader
    self.solanaSupport = solanaSupport ?? RainSolanaSupport(networkConfigs: networkConfigs)
    self.tokenStore = tokenStore ?? TokenMetadataStore(chainReader: chainReader)
    self.history = history ?? TurnkeyHistoryClient()
  }

  /// The reader for `chainId`'s chain family — the Solana reader for Solana clusters, the
  /// EVM reader otherwise.
  private func chainReaderFor(chainId: Int) -> ChainReader {
    RainChain.isSolana(chainId) ? solanaChainReader : chainReader
  }

  /// CAIP-2 for `chainId`: EIP-155 for EVM, genesis-hash form for Solana clusters.
  internal func caip2For(chainId: Int) -> String {
    ChainIDFormat.namespace(for: chainId).format(chainId: chainId)
  }

  /// True when Turnkey's `get-balances` API covers this chain (EVM allowlist or any Solana
  /// cluster). On any other chain, balance reads fall through to the injected `ChainReader`.
  private func usesTurnkeyForBalances(chainId: Int) -> Bool {
    TurnkeyBroadcastChains.balanceApiChainIds.contains(chainId) || RainChain.isSolana(chainId)
  }

  public func address() async throws -> String {
    if let walletAddressOverride, !walletAddressOverride.isEmpty {
      return walletAddressOverride
    }
    return try await resolveAddress(cache: \.cachedAddress, inFlight: \.addressResolution) {
      $0.resolveEthereumWalletAddress(from: $0.turnkey.wallets)
    }
  }

  /// Single-flight resolve-once: the cached value wins; otherwise concurrent callers share the
  /// in-flight Task (one wallet refresh). A failed Task is evicted so a later call retries.
  private func resolveAddress(
    cache: ReferenceWritableKeyPath<TurnkeyWalletProviderAdapter, String?>,
    inFlight: ReferenceWritableKeyPath<TurnkeyWalletProviderAdapter, Task<String, Error>?>,
    resolve: @escaping @Sendable (TurnkeyWalletProviderAdapter) -> String?
  ) async throws -> String {
    let task: Task<String, Error> = cachedAddressLock.withLock {
      evictAddressCachesIfSessionChanged()
      if let cached = self[keyPath: cache] {
        return Task { cached }
      }
      if let existing = self[keyPath: inFlight] {
        return existing
      }
      let task = Task { [self] in
        if let walletAddress = resolve(self) { return walletAddress }
        // Session-guarded: an expired session surfaces as tokenExpired here rather than as
        // the vendor's raw refresh-wallets failure.
        try await sessions.executeRead { _, _ in try await self.turnkey.refreshWallets() }
        if let walletAddress = resolve(self) { return walletAddress }
        throw RainError.walletUnavailable(details: "Turnkey session has no account for this chain family")
      }
      self[keyPath: inFlight] = task
      return task
    }

    do {
      let resolved = try await task.value
      cachedAddressLock.withLock {
        // Cache only while still the current resolution — a session change mid-flight evicted
        // this task, and its result belongs to the previous session.
        if self[keyPath: inFlight] == task {
          self[keyPath: cache] = resolved
          self[keyPath: inFlight] = nil
        }
      }
      return resolved
    } catch {
      cachedAddressLock.withLock {
        if self[keyPath: inFlight] == task { self[keyPath: inFlight] = nil }
      }
      throw error
    }
  }

  /// Chain-aware address. Solana chains resolve the Turnkey Solana account (base58, ed25519);
  /// every other chain shares the Ethereum account. Internal balance / send paths use this so
  /// a Solana request never reads or signs with the EVM address.
  public func getAddress(chainId: Int) async throws -> String {
    RainChain.isSolana(chainId) ? try await solanaAddress() : try await address()
  }

  private func solanaAddress() async throws -> String {
    // The `walletAddress` override is an EVM address, so it never applies to Solana.
    try await resolveAddress(cache: \.cachedSolanaAddress, inFlight: \.solanaAddressResolution) {
      $0.resolveSolanaWalletAddress(from: $0.turnkey.wallets)
    }
  }

  private func resolveSolanaWalletAddress(from wallets: [Wallet]) -> String? {
    wallets
      .flatMap(\.accounts)
      .first(where: { $0.addressFormat == .address_format_solana })?
      .address
  }

  public func sendTransaction(
    chainId: Int,
    params: WalletTransactionParams
  ) async throws -> String {
    try requireEVM(chainId: chainId, operation: "sendTransaction")
    // Every EVM broadcast funnels through here — withdrawals, approvals, transfers and
    // host-composed calldata — so the chain gate on this funnel covers them all.
    try requireSendSupport(chainId: chainId)
    // The body is rebuilt on a refresh-and-retry so the nonce and gas quotes stay fresh — that
    // retry can only happen BEFORE the submit: `sortedSendOutcome` turns every post-submit
    // failure into an outcome, so no 401 from the vendor's in-call poll reaches the coordinator.
    let outcome = try await sessions.executeWrite { session, client in
      let sendInput = try await self.buildTurnkeySendTransactionBody(
        session: session,
        client: client,
        chainId: chainId,
        params: params
      )
      return try await self.sortedSendOutcome(
        kind: .evm,
        matches: Self.evmIntentMatcher(sendInput)
      ) {
        try await client.ethSendTransaction(sendInput).sendTransactionStatusId
      }
    }
    let statusId = try await resolveStatusId(from: outcome, kind: .evm)
    return try await pollForTransactionHash(sendTransactionStatusId: statusId)
  }

  public func getBalance(
    chainId: Int,
    token: Token
  ) async throws -> Balance {
    let walletAddress = try await getAddress(chainId: chainId)

    // Solana has its own balance policy (Turnkey-first with an RPC fallback),
    // so it branches out before the EVM logic below.
    if RainChain.isSolana(chainId) {
      return try await solanaBalance(chainId: chainId, walletAddress: walletAddress, token: token)
    }

    switch token {
    case .contract(let address):
      // `eth_call balanceOf` is the same operation everywhere — delegate to the chain
      // reader so the SDK has one implementation rather than per-adapter copies.
      let info = await tokenStore.tokenInfo(chainId: chainId, address: address)
      return try await chainReaderFor(chainId: chainId).getBalance(
        chainId: chainId,
        walletAddress: walletAddress,
        token: token,
        tokenInfo: info
      )
    case .native:
      if !usesTurnkeyForBalances(chainId: chainId) {
        return try await chainReaderFor(chainId: chainId).getBalance(
          chainId: chainId,
          walletAddress: walletAddress,
          token: .native,
          tokenInfo: nil
        )
      }
      let balances = try await fetchBalances(chainId: chainId, walletAddress: walletAddress)
      return await nativeBalance(
        chainId: chainId,
        from: balances,
        caip2: caip2For(chainId: chainId)
      )
    }
  }

  /// Solana balance read. Turnkey is the primary source, with the Solana RPC reader as the
  /// fallback for both native SOL and SPL tokens — Turnkey does not index every cluster (devnet
  /// in particular), and the node always does.
  private func solanaBalance(
    chainId: Int,
    walletAddress: String,
    token: Token
  ) async throws -> Balance {
    do {
      let balances = try await fetchBalances(chainId: chainId, walletAddress: walletAddress)
      let caip2 = caip2For(chainId: chainId)
      switch token {
      case .native:
        return await nativeBalance(chainId: chainId, from: balances, caip2: caip2)
      case .contract(let mint):
        return try await splBalance(
          chainId: chainId,
          walletAddress: walletAddress,
          from: balances,
          caip2: caip2,
          mint: mint
        )
      }
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch let error as RainError where error == .tokenExpired {
      // A dead session must surface, not be masked by the node fallback — the coordinator
      // already tried a refresh before this error was thrown.
      throw error
    } catch {
      return try await chainReaderFor(chainId: chainId).getBalance(
        chainId: chainId,
        walletAddress: walletAddress,
        token: token,
        tokenInfo: await solanaTokenInfo(chainId: chainId, token: token)
      )
    }
  }

  /// Host-registered metadata for a mint, if any — the naming source for the chain-fallback
  /// path. Reads only the registry, never `TokenMetadataStore.tokenInfo`, whose enrichment path
  /// goes through the EVM reader and cannot describe an SPL mint.
  private func solanaTokenInfo(chainId: Int, token: Token) async -> TokenInfo? {
    guard case .contract(let mint) = token else { return nil }
    return await tokenStore.registeredTokens(for: chainId)
      .first { $0.address.lowercased() == mint.lowercased() }
  }

  /// Native SOL plus the SPL tokens the wallet holds, read from the node. Zero balances are
  /// dropped, matching every other chain. Naming falls back to host-registered tokens, so a
  /// mint no indexer covers can still be labelled by the caller rather than shown as a bare
  /// address.
  private func solanaBalancesFromNode(
    chainId: Int,
    walletAddress: String
  ) async throws -> [Balance] {
    let all = try await chainReaderFor(chainId: chainId).getBalances(
      chainId: chainId,
      walletAddress: walletAddress,
      tokens: await tokenStore.registeredTokens(for: chainId)
    )
    return all.filter { balance in
      if case .native = balance.token { return true }
      return balance.rawAmount > 0
    }
  }

  /// Builds an SPL `Balance` for `mint` from a Turnkey asset list.
  ///
  /// Turnkey omits zero balances, and on a cluster it does not index every mint looks like a
  /// zero — so a missing entry is re-read from the node rather than reported as zero with
  /// unknown decimals.
  private func splBalance(
    chainId: Int,
    walletAddress: String,
    from balances: [v1AssetBalance],
    caip2: String,
    mint: String
  ) async throws -> Balance {
    guard let asset = balances.first(where: { tokenAddress(from: $0.caip19 ?? "", caip2: caip2) == mint })
    else {
      return try await chainReaderFor(chainId: chainId).getBalance(
        chainId: chainId,
        walletAddress: walletAddress,
        token: .contract(address: mint),
        tokenInfo: await solanaTokenInfo(chainId: chainId, token: .contract(address: mint))
      )
    }
    let raw = BigUInt(asset.balance ?? "0") ?? 0
    return await contractBalanceFrom(chainId: chainId, tokenAddress: mint, raw: raw, balance: asset)
  }

  public func getBalances(
    chainId: Int
  ) async throws -> [Balance] {
    let walletAddress = try await getAddress(chainId: chainId)

    if !usesTurnkeyForBalances(chainId: chainId) {
      let tokens = await tokenStore.registeredTokens(for: chainId)
      let all = try await chainReaderFor(chainId: chainId).getBalances(
        chainId: chainId,
        walletAddress: walletAddress,
        tokens: tokens
      )
      return all.filter { balance in
        if case .native = balance.token { return true }
        return balance.rawAmount > 0
      }
    }

    let caip2 = caip2For(chainId: chainId)
    let balances: [v1AssetBalance]
    if RainChain.isSolana(chainId) {
      let turnkeyBalances: [v1AssetBalance]?
      do {
        turnkeyBalances = try await fetchBalances(chainId: chainId, walletAddress: walletAddress)
      } catch let cancellation as CancellationError {
        throw cancellation
      } catch let error as RainError where error == .tokenExpired {
        // A dead session must surface, not be masked by the node fallback.
        throw error
      } catch {
        turnkeyBalances = nil
      }
      // Turnkey does not index every cluster: on devnet / testnet it errors, or answers with SOL
      // and no SPL assets at all. Discovering the wallet's token accounts from the node covers
      // both cases; on mainnet, where Turnkey does list SPL assets, its richer metadata wins.
      let listsSplAssets = turnkeyBalances?.contains { balance in
        tokenAddress(from: balance.caip19 ?? "", caip2: caip2) != nil
      } ?? false
      guard let turnkeyBalances, listsSplAssets else {
        return try await solanaBalancesFromNode(chainId: chainId, walletAddress: walletAddress)
      }
      balances = turnkeyBalances
    } else {
      balances = try await fetchBalances(chainId: chainId, walletAddress: walletAddress)
    }

    var output: [Balance] = [await nativeBalance(chainId: chainId, from: balances, caip2: caip2)]
    for balance in balances {
      guard let caip19 = balance.caip19,
            let tokenAddress = tokenAddress(from: caip19, caip2: caip2)
      else {
        continue
      }
      let raw = BigUInt(balance.balance ?? "0") ?? 0
      guard raw > 0 else { continue }
      output.append(
        await contractBalanceFrom(chainId: chainId, tokenAddress: tokenAddress, raw: raw, balance: balance)
      )
    }
    return output
  }

  /// Builds a contract-token `Balance` from a Turnkey asset entry. EVM tokens are enriched via
  /// `tokenStore` (registry / on-chain `decimals()`+`symbol()`) with Turnkey's values taking
  /// precedence; Solana SPL tokens use Turnkey's metadata directly, since the Solana reader
  /// can't enrich and would only cache misleading defaults.
  private func contractBalanceFrom(
    chainId: Int,
    tokenAddress: String,
    raw: BigUInt,
    balance: v1AssetBalance?
  ) async -> Balance {
    if RainChain.isSolana(chainId) {
      return Balance(
        token: .contract(address: tokenAddress),
        chainId: chainId,
        rawAmount: raw,
        decimals: balance?.decimals ?? 0,
        symbol: balance?.symbol,
        name: balance?.name
      )
    }
    let info = await tokenStore.tokenInfo(chainId: chainId, address: tokenAddress)
    return Balance(
      token: .contract(address: tokenAddress),
      chainId: chainId,
      rawAmount: raw,
      decimals: balance?.decimals ?? info.decimals,
      symbol: balance?.symbol ?? info.symbol,
      name: balance?.name ?? info.name
    )
  }

  /// Builds the native `Balance` from a Turnkey asset list. Turnkey reports balances in raw
  /// base units, so the string is parsed directly as `BigUInt` (no decimal reconstruction).
  private func nativeBalance(
    chainId: Int,
    from balances: [v1AssetBalance],
    caip2: String
  ) async -> Balance {
    let nativeAsset = balances.first(where: { isNativeAsset($0, caip2: caip2) })
    let raw = BigUInt(nativeAsset?.balance ?? "0") ?? 0
    let native = await tokenStore.nativeCurrency(for: chainId)
    return Balance(
      token: .native,
      chainId: chainId,
      rawAmount: raw,
      decimals: nativeAsset?.decimals ?? native.decimals,
      symbol: native.symbol,
      name: native.name
    )
  }

  /// Transaction history. Turnkey's indexed history queries are the primary source, since they
  /// cover the wallet's full on-chain history (receives and externally-submitted transactions
  /// included). When the indexed query is unavailable, most commonly because the history feature
  /// is not enabled for the Turnkey organization, the adapter falls back to the activity log,
  /// which lists only transactions sent through Turnkey.
  public func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    do {
      if RainChain.isSolana(chainId) {
        return try await indexedSolanaTransactions(chainId: chainId, limit: limit, offset: offset, order: order)
      }
      return try await indexedEvmTransactions(chainId: chainId, limit: limit, offset: offset, order: order)
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch let error as RainError where error == .tokenExpired {
      // The activity path needs the same session, so falling back would only fail again.
      throw error
    } catch TurnkeySwiftError.invalidSession {
      throw TurnkeySwiftError.invalidSession
    } catch {
      // URLSession surfaces task cancellation as URLError(.cancelled), not CancellationError;
      // a cancelled call must not run the fallback.
      if Task.isCancelled { throw error }
      RainLogger.warning("Rain SDK: Turnkey indexed history unavailable, falling back to activities: \(error)")
    }
    if RainChain.isSolana(chainId) {
      return try await solanaTransactionsFromActivities(chainId: chainId, limit: limit, offset: offset, order: order)
    }
    return try await evmTransactionsFromActivities(chainId: chainId, limit: limit, offset: offset, order: order)
  }

  private func indexedEvmTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    let walletAddress = try await getAddress(chainId: chainId)
    let response = try await sessions.executeRead { session, _ in
      try await self.history.listEthTransactionHistory(
        organizationId: session.organizationId,
        sessionPublicKey: session.publicKey,
        address: walletAddress,
        caip2: self.caip2For(chainId: chainId),
        limit: self.requestedHistoryLimit(limit: limit, offset: offset)
      )
    }
    let rows = (response.transactions ?? []).map { tx in
      (
        Self.rfc3339EpochSeconds(tx.block?.timestamp),
        indexedTransaction(
          chainId: chainId,
          walletAddress: walletAddress,
          hash: tx.transactionHash,
          block: tx.block,
          status: tx.status,
          txFrom: tx.from,
          txTo: tx.to,
          transfer: tx.transfers?.first,
          sponsored: tx.turnkey?.sponsored
        )
      )
    }
    return sortAndSlice(rows: rows, limit: limit, offset: offset, order: order)
  }

  private func indexedSolanaTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    let walletAddress = try await getAddress(chainId: chainId)
    let response = try await sessions.executeRead { session, _ in
      try await self.history.listSolTransactionHistory(
        organizationId: session.organizationId,
        sessionPublicKey: session.publicKey,
        address: walletAddress,
        caip2: self.caip2For(chainId: chainId),
        limit: self.requestedHistoryLimit(limit: limit, offset: offset)
      )
    }
    let rows = (response.transactions ?? []).map { tx in
      (
        Self.rfc3339EpochSeconds(tx.block?.timestamp),
        indexedTransaction(
          chainId: chainId,
          walletAddress: walletAddress,
          hash: tx.signature,
          block: tx.block,
          status: tx.status,
          txFrom: tx.feePayer,
          txTo: nil,
          transfer: tx.transfers?.first,
          sponsored: tx.turnkey?.sponsored
        )
      )
    }
    return sortAndSlice(rows: rows, limit: limit, offset: offset, order: order)
  }

  /// Maps one indexed history row onto the Rain model. The row's first transfer supplies the
  /// counterparty, asset and amount; any further transfers on the same transaction (a swap's
  /// received leg, a batch's other recipients) are not rendered as rows. A row without transfers
  /// (e.g. a plain contract call) keeps the transaction-level addresses and carries no amount.
  private func indexedTransaction(
    chainId: Int,
    walletAddress: String,
    hash: String,
    block: TurnkeyHistoryBlock?,
    status: String?,
    txFrom: String?,
    txTo: String?,
    transfer: TurnkeyHistoryTransfer?,
    sponsored: Bool?
  ) -> RainTransaction {
    let incoming = transfer?.direction?.uppercased() == "IN"
    // Turnkey sends "" (not null) when the counterparty is unknown, Solana in particular.
    let counterparty = transfer?.counterparty.flatMap {
      $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
    }
    let asset = transfer?.asset?.caip19.flatMap {
      Self.caip19Asset(from: $0, caip2: caip2For(chainId: chainId))
    }
    let transferTokenAddress = asset.flatMap {
      $0.namespace == Self.nativeAssetNamespace ? nil : $0.reference
    }
    // Indexer-supplied; a value outside any real token's range must not scale the amount.
    let decimals = transfer?.asset?.decimals.flatMap {
      (0...Self.maxTokenDecimals).contains($0) ? $0 : nil
    }
    var displayValues: [String: String] = [:]
    if let crypto = transfer?.display?.crypto { displayValues["crypto"] = crypto }
    if let usd = transfer?.display?.usd { displayValues["usd"] = usd }

    let from: String
    let to: String?
    if transfer != nil {
      if incoming {
        from = counterparty ?? txFrom ?? walletAddress
        to = walletAddress
      } else {
        // OUT is relative to the queried address: the wallet is the sender even when the
        // transaction-level `from` is a sponsor, relayer or bundler.
        from = walletAddress
        to = counterparty ?? txTo
      }
    } else {
      from = txFrom ?? walletAddress
      to = txTo
    }

    var value: Decimal?
    if let amount = transfer?.amount, let decimals {
      value = Self.exactDecimal(amount: amount, decimals: decimals)
    }

    let type: String?
    if transfer == nil {
      type = nil
    } else {
      type = incoming ? "transferReceived" : "transferSent"
    }

    return RainTransaction(
      hash: hash,
      uniqueId: hash,
      blockNumber: block?.number,
      timestamp: Self.normalizedTimestamp(block?.timestamp),
      from: from,
      to: to,
      value: value,
      asset: transfer?.asset?.symbol,
      tokenAddress: transferTokenAddress,
      rawValue: transfer?.amount,
      decimals: decimals,
      category: Self.indexedCategory(of: asset),
      chainId: chainId,
      metadata: RainTransaction.Metadata(
        caip2: caip2For(chainId: chainId),
        status: Self.indexerStatus(status),
        sponsored: sponsored,
        type: type,
        displayValues: displayValues.isEmpty ? nil : displayValues
      )
    )
  }

  private struct Caip19Asset {
    let namespace: String
    let reference: String
  }

  /// CAIP-19 asset namespace of a chain's native coin (ETH, SOL).
  private static let nativeAssetNamespace = "slip44"

  /// Widest plausible token scale (uint256 spans 78 digits); beyond this is hostile data.
  private static let maxTokenDecimals = 77

  /// Splits a CAIP-19 under `caip2` into asset namespace and reference; `nil` when foreign or
  /// malformed. Every access is guarded: this parses indexer-supplied strings, which must never
  /// be able to crash the host.
  private static func caip19Asset(from caip19: String, caip2: String) -> Caip19Asset? {
    let prefix = "\(caip2)/"
    guard caip19.hasPrefix(prefix) else { return nil }
    let rest = caip19.dropFirst(prefix.count)
    let parts = rest.split(separator: ":", maxSplits: 1)
    guard parts.count == 2,
          let referencePart = parts[1].split(separator: "/", maxSplits: 1).first
    else { return nil }
    let namespace = String(parts[0])
    let reference = String(referencePart)
    guard !namespace.isEmpty, !reference.isEmpty else { return nil }
    return Caip19Asset(namespace: namespace, reference: reference)
  }

  private static func indexedCategory(of asset: Caip19Asset?) -> RainTransactionCategory {
    switch asset?.namespace {
    case nil, nativeAssetNamespace: return .external
    case "erc20": return .erc20
    case "erc721": return .erc721
    case "erc1155": return .erc1155
    default: return .token
    }
  }

  /// `EXECUTION_REVERTED` becomes `executionReverted`, matching the Privy rows' vocabulary.
  private static func indexerStatus(_ status: String?) -> String? {
    guard let status else { return nil }
    let parts = status.lowercased().split(separator: "_").filter { !$0.isEmpty }
    guard let first = parts.first else { return nil }
    return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined()
  }

  /// Exact atomic-units scaling; `nil` for a non-numeric amount or indexer-supplied decimals
  /// outside a sane token range, never a fabricated zero and never an overflow trap.
  private static func exactDecimal(amount: String, decimals: Int) -> Decimal? {
    guard (0...maxTokenDecimals).contains(decimals) else { return nil }
    let value = NSDecimalNumber(string: amount)
    guard value != NSDecimalNumber.notANumber else { return nil }
    let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(decimals), isNegative: false)
    return value.dividing(by: divisor) as Decimal
  }

  /// Same fetch window as the activity path: enough rows to honor `offset`, capped by the API.
  private func requestedHistoryLimit(limit: Int?, offset: Int?) -> Int {
    min(max((limit ?? 10) + (offset ?? 0), 1), 100)
  }

  private func sortAndSlice(
    rows: [(TimeInterval, RainTransaction)],
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) -> [RainTransaction] {
    // Swift's sort is not stability-guaranteed, so rows sharing a block timestamp keep the
    // API's newest-first order via the index tiebreak.
    let sorted = rows.enumerated().sorted { lhs, rhs in
      switch order ?? .DESC {
      case .ASC:
        if lhs.element.0 != rhs.element.0 { return lhs.element.0 < rhs.element.0 }
        return lhs.offset > rhs.offset
      case .DESC:
        if lhs.element.0 != rhs.element.0 { return lhs.element.0 > rhs.element.0 }
        return lhs.offset < rhs.offset
      }
    }
    return Array(
      sorted
        .dropFirst(offset ?? 0)
        .prefix(limit ?? sorted.count)
    ).map { $0.element.1 }
  }

  /// Sort key for an indexed row with no mined block yet: newest, not 1970.
  private static let pendingRowEpoch = TimeInterval.greatestFiniteMagnitude

  /// Epoch seconds for an RFC 3339 timestamp. A row without one (not mined yet, or a form the
  /// parser does not know) sorts as newest rather than 1970, so a pending send stays on the
  /// first page instead of being sliced off the end.
  private static func rfc3339EpochSeconds(_ timestamp: String?) -> TimeInterval {
    guard let timestamp, !timestamp.isEmpty else { return pendingRowEpoch }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: timestamp) { return date.timeIntervalSince1970 }
    let plain = ISO8601DateFormatter()
    return plain.date(from: timestamp)?.timeIntervalSince1970 ?? pendingRowEpoch
  }

  /// The indexer's timestamp reduced to the second-precision Zulu the activity path emits.
  private static func normalizedTimestamp(_ timestamp: String?) -> String? {
    guard let timestamp, !timestamp.isEmpty else { return nil }
    let epoch = rfc3339EpochSeconds(timestamp)
    return epoch == pendingRowEpoch ? timestamp : iso8601String(from: epoch)
  }

  /// Activity-log history, used when the indexed query is unavailable. Sends only, no receives.
  private func evmTransactionsFromActivities(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    let requestedLimit = min(max((limit ?? 10) + (offset ?? 0), 1), 100)
    let activitiesResponse = try await sessions.executeRead { session, client in
      try await client.getActivities(
        TGetActivitiesBody(
          organizationId: session.organizationId,
          filterByType: [.activity_type_eth_send_transaction],
          paginationOptions: v1Pagination(limit: String(requestedLimit))
        )
      )
    }

    let matchingDrafts = activitiesResponse.activities.compactMap { activity in
      draftTransaction(from: activity, expectedChainId: chainId)
    }

    let sortedDrafts = matchingDrafts.sorted { lhs, rhs in
      switch order ?? .DESC {
      case .ASC:
        return lhs.timestamp < rhs.timestamp
      case .DESC:
        return lhs.timestamp > rhs.timestamp
      }
    }

    let slicedDrafts = Array(
      sortedDrafts
        .dropFirst(offset ?? 0)
        .prefix(limit ?? sortedDrafts.count)
    )

    var transactions: [RainTransaction] = []
    transactions.reserveCapacity(slicedDrafts.count)

    for draft in slicedDrafts {
      let txHash = try? await resolveTransactionHash(
        sendTransactionStatusId: draft.sendTransactionStatusId
      )
      // A contract call carries calldata; a plain transfer does not.
      let isContractCall = draft.data.map { $0 != "0x" && !$0.isEmpty } ?? false

      transactions.append(
        RainTransaction(
          hash: txHash ?? draft.id,
          uniqueId: draft.id,
          timestamp: Self.iso8601String(from: draft.timestamp),
          from: draft.from,
          to: draft.to,
          value: decimalStringToDecimal(
            balance: draft.value,
            decimals: Self.AdapterConstants.defaultNativeDecimals
          ),
          tokenAddress: isContractCall ? draft.to : nil,
          rawValue: draft.value,
          decimals: Self.AdapterConstants.defaultNativeDecimals,
          category: .external,
          chainId: draft.chainId
        )
      )
    }

    return transactions
  }

  private struct SolanaActivityDraft: Sendable {
    let id: String
    let timestamp: TimeInterval
    let from: String
    let to: String?
    let lamports: UInt64?
    let sendTransactionStatusId: String?
    /// Set instead of `lamports` when the activity was an SPL transfer.
    let token: SolanaTransactionDecoder.TokenTransfer?
  }

  /// Solana activity-log history (`ACTIVITY_TYPE_SOL_SEND_TRANSACTION`), used when the indexed
  /// query is unavailable. Shows only transactions this wallet sent through Turnkey (no
  /// receives). Turnkey's Solana activity carries only the unsigned transaction (no
  /// recipient/amount) and no on-chain signature, so `to`/`value` are decoded from that blob and
  /// the row's hash is the Turnkey status id (not an explorer-resolvable signature).
  ///
  /// Both shapes Rain sends are decoded: a System transfer becomes a native SOL row, and an SPL
  /// `TransferChecked` a token row carrying the mint in `rawContract`. SPL transfers move between
  /// *token accounts*, so the recipient wallet is recovered from the transaction's
  /// account-creation instruction when it has one, and read from the node otherwise.
  private func solanaTransactionsFromActivities(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    let caip2 = caip2For(chainId: chainId)
    let requestedLimit = min(max((limit ?? 10) + (offset ?? 0), 1), 100)
    let activitiesResponse = try await sessions.executeRead { session, client in
      try await client.getActivities(
        TGetActivitiesBody(
          organizationId: session.organizationId,
          filterByType: [.activity_type_sol_send_transaction],
          paginationOptions: v1Pagination(limit: String(requestedLimit))
        )
      )
    }

    let drafts: [SolanaActivityDraft] = activitiesResponse.activities.compactMap { activity in
      guard let intent = activity.intent.solSendTransactionIntent,
            intent.caip2 == caip2 else {
        return nil
      }
      let seconds = Double(activity.createdAt.seconds) ?? 0
      let nanos = Double(activity.createdAt.nanos) ?? 0
      let transfer = SolanaTransactionDecoder.decodeTransfer(intent.unsignedTransaction)
      let token = transfer == nil
        ? SolanaTransactionDecoder.decodeTokenTransfer(intent.unsignedTransaction)
        : nil
      return SolanaActivityDraft(
        id: activity.id,
        timestamp: seconds + nanos / 1_000_000_000,
        from: intent.signWith,
        to: transfer?.to ?? token?.destinationOwner ?? token?.destination,
        lamports: transfer?.lamports,
        sendTransactionStatusId: activity.result.solSendTransactionResult?.sendTransactionStatusId,
        token: token
      )
    }

    let sortedDrafts = drafts.sorted { lhs, rhs in
      switch order ?? .DESC {
      case .ASC: return lhs.timestamp < rhs.timestamp
      case .DESC: return lhs.timestamp > rhs.timestamp
      }
    }

    let slicedDrafts = Array(
      sortedDrafts
        .dropFirst(offset ?? 0)
        .prefix(limit ?? sortedDrafts.count)
    )

    var transactions: [RainTransaction] = []
    transactions.reserveCapacity(slicedDrafts.count)
    for draft in slicedDrafts {
      transactions.append(await solanaTransaction(chainId: chainId, from: draft))
    }
    return transactions
  }

  /// Maps one decoded Solana activity onto the Rain model. SPL rows resolve their decimals and
  /// recipient wallet from the node when the transaction itself didn't carry them; both reads are
  /// best-effort, so a row always lists.
  private func solanaTransaction(
    chainId: Int,
    from draft: SolanaActivityDraft
  ) async -> RainTransaction {
    var value = draft.lamports.map { SolanaConverter.lamportsToSol($0) }
    var asset: String? = RainChain.solanaNativeCurrency.symbol
    var category = RainTransactionCategory.external
    var tokenAddress: String?
    var rawValue: String?
    var resolvedDecimals: Int?
    var metadata: RainTransaction.Metadata?
    var to = draft.to

    if let token = draft.token {
      category = .token
      let mint = token.mint
      // TransferChecked carries the decimals; the bare Transfer instruction does not.
      var decimals = token.decimals.map(Int.init)
      if decimals == nil, let mint {
        decimals = try? await solanaRpcClient.getMintInfo(chainId: chainId, mint: mint)?.decimals
      }
      value = decimals.map {
        EthereumConverter.baseUnitsToDecimal(BigUInt(token.rawAmount.description) ?? 0, decimals: $0)
      }
      // Registered metadata only — enrichment reads `decimals()` over EVM RPC, which no mint answers.
      asset = nil
      if let mint {
        asset = await tokenStore.registeredTokens(for: chainId)
          .first { $0.address == mint }?
          .symbol
      }
      tokenAddress = mint
      rawValue = "\(token.rawAmount)"
      resolvedDecimals = decimals
      // The token accounts are not reconstructible from `to`, which holds the wallet when the
      // owner read succeeded and the token account when it didn't.
      metadata = RainTransaction.Metadata(
        sourceTokenAccount: token.source,
        destinationTokenAccount: token.destination
      )
      if token.destinationOwner == nil {
        // Falls back to the token account when the owner cannot be read — a real address the user
        // can look up, rather than nothing.
        let owner = try? await solanaRpcClient.getTokenAccount(
          chainId: chainId, address: token.destination
        )
        to = owner?.owner.isEmpty == false ? owner?.owner : token.destination
      }
    }

    return RainTransaction(
      hash: draft.sendTransactionStatusId ?? draft.id,
      uniqueId: draft.id,
      timestamp: Self.iso8601String(from: draft.timestamp),
      from: draft.from,
      to: to,
      value: value,
      asset: asset,
      tokenAddress: tokenAddress,
      rawValue: rawValue,
      decimals: resolvedDecimals,
      category: category,
      chainId: chainId,
      metadata: metadata
    )
  }

  // MARK: - Solana send

  func sendSolanaNative(
    chainId: Int,
    to toAddress: String,
    amount: Decimal
  ) async throws -> String {
    // Gated before composing so no RPC work runs for a cluster Turnkey cannot broadcast on.
    try requireSendSupport(chainId: chainId)
    let from = try await getAddress(chainId: chainId)
    let unsigned = try await solanaTransferComposer.composeNative(
      chainId: chainId, from: from, to: toAddress, amount: amount
    )
    return try await submitSolanaTransaction(chainId: chainId, from: from, unsigned: unsigned)
  }

  /// Signs and broadcasts a transaction core composed (a collateral withdrawal). The bytes are
  /// signed as handed over — rebuilding them would invalidate the coordinator signature they embed.
  func signAndSendSolanaTransaction(
    chainId: Int,
    unsigned: UnsignedSolanaTransfer
  ) async throws -> String {
    let from = try await getAddress(chainId: chainId)
    return try await submitSolanaTransaction(chainId: chainId, from: from, unsigned: unsigned)
  }

  /// Hands a composed transfer to Turnkey (which signs with the wallet's ed25519 key and
  /// broadcasts) and resolves it to a signature. Shared by the native and SPL paths.
  ///
  /// The Turnkey type documents `unsignedTransaction` as base64, but the live API hex-decodes it
  /// (see `SolanaTransactionBuilder`), so the hex form is sent.
  private func submitSolanaTransaction(
    chainId: Int,
    from: String,
    unsigned: UnsignedSolanaTransfer
  ) async throws -> String {
    // Every Solana broadcast funnels through here; gate it like the EVM funnel so no caller can
    // reach solSendTransaction on an unsupported cluster (Turnkey covers mainnet + devnet only).
    try requireSendSupport(chainId: chainId)
    // Baseline for the signature recovery below: the wallet's newest signature before this send.
    let priorSignature = try? await solanaRpcClient.getLatestSignature(chainId: chainId, address: from)

    // Post-submit failures become outcomes inside the write (see `sortedSendOutcome`), so the
    // coordinator's refresh-and-retry can never re-run an accepted submit.
    let outcome = try await sessions.executeWrite { session, client in
      let body = TSolSendTransactionBody(
        organizationId: session.organizationId,
        caip2: self.caip2For(chainId: chainId),
        recentBlockhash: unsigned.recentBlockhash,
        signWith: from,
        // Sponsored: Turnkey covers the network fee (rent for a first-time recipient token
        // account is a separate Turnkey toggle and stays the sender's). Signature recovery
        // below keys on this wallet's own signature, so it holds whichever key pays.
        sponsor: self.sponsorsFees(chainId: chainId),
        unsignedTransaction: unsigned.transactionHex
      )
      return try await self.sortedSendOutcome(
        kind: .solana,
        matches: Self.solanaIntentMatcher(body)
      ) {
        try await client.solSendTransaction(body).sendTransactionStatusId
      }
    }
    let statusId = try await resolveStatusId(from: outcome, kind: .solana)

    // The Turnkey SDK returns the Solana signature in the send-status response once Included.
    if let signature = try await pollForSolanaCompletion(sendTransactionStatusId: statusId) {
      return signature
    }

    // Defensive fallback: recover the signature from chain. `getSignaturesForAddress` lags
    // broadcast slightly, so retry briefly before falling back to the status id. Only a signature
    // that differs from the pre-send baseline can belong to this send — returning the baseline
    // itself would report an older, unrelated transaction as this one.
    for attempt in 0..<AdapterConstants.solanaSignatureLookupAttempts {
      if let signature = try await solanaRpcClient.getLatestSignature(chainId: chainId, address: from),
         signature != priorSignature {
        return signature
      }
      if attempt + 1 < AdapterConstants.solanaSignatureLookupAttempts {
        try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
      }
    }
    return statusId
  }

  // MARK: - SPL token send

  /// Sends SPL tokens. Composition and every preflight (mint resolution, token-account
  /// derivation/creation, balance and fee checks, simulation) live in ``SolanaTransferComposer``;
  /// this method only signs and broadcasts through Turnkey.
  ///
  /// `decimals` is deliberately unread — it is not authoritative here. The composer reads the
  /// mint's own scale from the chain, which `TransferChecked` then enforces.
  func sendSolanaSPLToken(
    chainId: Int,
    mintAddress: String,
    to toAddress: String,
    amount: Decimal,
    decimals: Int
  ) async throws -> String {
    try requireSendSupport(chainId: chainId)
    let from = try await getAddress(chainId: chainId)
    let unsigned = try await solanaTransferComposer.composeSPLToken(
      chainId: chainId,
      from: from,
      mintAddress: mintAddress,
      to: toAddress,
      amount: amount,
      // A sponsored send skips the self-paid fee check and dry run, and carries the System
      // Program key Turnkey's sponsored path can require.
      sponsoredFees: sponsorsFees(chainId: chainId)
    )
    return try await submitSolanaTransaction(chainId: chainId, from: from, unsigned: unsigned)
  }

  /// Polls Turnkey for the terminal status of a Solana submission. Returns `solana.signature`
  /// (populated once the tx is Included), `nil` at a terminal status without it or on timeout
  /// (caller then recovers the signature from chain), and throws on explicit failure.
  private func pollForSolanaCompletion(
    sendTransactionStatusId: String
  ) async throws -> String? {
    for attempt in 0..<AdapterConstants.defaultPollingAttempts {
      // A session dying mid-poll stops the status reads, not the submitted transaction:
      // returning nil lets the caller recover the signature from chain.
      let status: TGetSendTransactionStatusResponse
      do {
        status = try await sessions.executeRead { session, client in
          try await client.getSendTransactionStatus(
            TGetSendTransactionStatusBody(
              organizationId: session.organizationId,
              sendTransactionStatusId: sendTransactionStatusId
            )
          )
        }
      } catch let error as RainError where error == .tokenExpired {
        return nil
      }

      if let failure = Self.sendFailure(
        from: status, fallbackMessage: "Turnkey Solana transaction submission failed"
      ) {
        throw failure
      }
      let normalized = status.txStatus.uppercased()

      if let signature = status.solana?.signature, !signature.isEmpty {
        return signature
      }

      // Terminal status but no signature yet: stop; the caller recovers it from chain.
      if normalized.contains("INCLUDED") || normalized.contains("CONFIRMED")
        || normalized.contains("FINALIZED") || normalized.contains("MINED")
      {
        return nil
      }

      if attempt + 1 < AdapterConstants.defaultPollingAttempts {
        try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
      }
    }
    return nil
  }

  func signTypedData(
    chainId: Int,
    walletAddress: String,
    typedData: String
  ) async throws -> String {
    try requireEVM(chainId: chainId, operation: "signTypedData")
    let signature = try await sessions.executeWrite { _, _ in
      try await self.turnkey.signRawPayload(
        signWith: walletAddress,
        payload: typedData,
        encoding: .payload_encoding_eip712,
        hashFunction: .hash_function_no_op
      )
    }

    return Self.ethereumSignatureHex(from: signature)
  }

  func estimateTransactionFee(
    chainId: Int,
    walletAddress: String,
    params: WalletTransactionParams
  ) async throws -> Decimal {
    try requireEVM(chainId: chainId, operation: "estimateTransactionFee")
    // Deliberately NOT short-circuited to zero when sponsored: the estimate is what the send
    // WOULD cost on chain, so a host can show the user what sponsorship saves them. The
    // sponsored send itself never charges the wallet.
    let estimateHex = try await rpcCallForHex(
      chainId: chainId,
      method: "eth_estimateGas",
      params: [rpcTransactionObject(from: params)]
    )
    let gasPriceHex = try await rpcCallForHex(
      chainId: chainId,
      method: "eth_gasPrice",
      params: []
    )

    // Exact wei math: multiply as BigUInt, divide to native units as Decimal.
    let gasLimit = try EthereumConverter.parseHexToBigUIntStrict(estimateHex)
    let gasPriceWei = try EthereumConverter.parseHexToBigUIntStrict(gasPriceHex)

    return EthereumConverter.baseUnitsToDecimal(
      gasLimit * gasPriceWei,
      decimals: AdapterConstants.defaultNativeDecimals
    )
  }

  /// Rejects Solana chain ids on the EVM-only paths; Solana transfers go through `sendNative` /
  /// `sendToken`.
  private func requireEVM(chainId: Int, operation: String) throws {
    guard RainChain.isSolana(chainId) else { return }
    throw RainError.invalidConfig(
      details: "Turnkey provider does not support \(operation) on Solana; use sendNative for SOL transfers"
    )
  }

  private func fetchBalances(
    chainId: Int,
    walletAddress: String
  ) async throws -> [v1AssetBalance] {
    let response = try await sessions.executeRead { session, client in
      try await client.getWalletAddressBalances(
        TGetWalletAddressBalancesBody(
          organizationId: session.organizationId,
          address: walletAddress,
          caip2: self.caip2For(chainId: chainId)
        )
      )
    }

    return response.balances ?? []
  }

  private func buildTurnkeySendTransactionBody(
    session: Session,
    client: any TurnkeyClientProtocol,
    chainId: Int,
    params: WalletTransactionParams
  ) async throws -> TEthSendTransactionBody {
    if sponsorsFees(chainId: chainId) {
      // Sponsored sends are minimal payloads. Turnkey's Gas Station builds and fee-covers the
      // outer EIP-7702 transaction, so this wallet's account nonce and self-estimated fees are
      // the wrong values to pin (the outer tx is not this account's), and estimating gas as if
      // the sender paid would also reject the zero-balance wallets sponsorship exists for.
      // Omitted fields are auto-filled by Turnkey.
      //
      // Replay protection is the gas-station nonce, and Turnkey's one-transaction-per-request
      // guarantee holds only when the request carries it. Fetched here with one Turnkey call
      // (not a chain RPC, so zero-balance wallets are unaffected) and refetched on every
      // refresh-and-retry rebuild. A nil from Turnkey is omitted, falling back to their
      // server-side fetch.
      let gasStationNonce = try await client.getNonces(
        TGetNoncesBody(
          organizationId: session.organizationId,
          address: params.from,
          caip2: ChainIDFormat.EIP155.format(chainId: chainId),
          gasStationNonce: true
        )
      ).gasStationNonce
      return TEthSendTransactionBody(
        organizationId: session.organizationId,
        caip2: ChainIDFormat.EIP155.format(chainId: chainId),
        data: normalizedData(params.data),
        from: params.from,
        gasStationNonce: gasStationNonce,
        sponsor: true,
        to: params.to,
        value: decimalString(fromHex: params.value)
      )
    }

    let nonceHex = try await rpcCallForHex(
      chainId: chainId,
      method: "eth_getTransactionCount",
      params: [params.from, "pending"]
    )
    let estimateGasHex = try await rpcCallForHex(
      chainId: chainId,
      method: "eth_estimateGas",
      params: [rpcTransactionObject(from: params)]
    )
    let gasPriceHex = try await rpcCallForHex(
      chainId: chainId,
      method: "eth_gasPrice",
      params: []
    )

    let nonce = decimalString(fromHex: nonceHex)
    // `decimalString(fromHex:)` yields "0" (not nil) for a zero or unparseable estimate, so the
    // fallback has to key off the value, not off a failed conversion.
    let parsedGas = BigUInt(decimalString(fromHex: estimateGasHex)) ?? 0
    // 21,000 is the intrinsic cost of a bare transfer with no calldata; a contract call sent with
    // it runs out of gas and reverts, burning the fee. Fail loudly instead of underestimating.
    guard parsedGas > 0 || normalizedData(params.data) == "0x" else {
      throw RainError.internalError(
        details: "eth_estimateGas returned no usable gas limit for a contract call"
      )
    }
    let estimatedGas = parsedGas > 0 ? parsedGas : BigUInt(AdapterConstants.fallbackGasLimit)
    let bufferedGasLimit = estimatedGas + (estimatedGas / 5)
    let gasLimit = (bufferedGasLimit == 0 ? estimatedGas : bufferedGasLimit).description
    let gasPrice = decimalString(fromHex: gasPriceHex)

    return TEthSendTransactionBody(
      organizationId: session.organizationId,
      caip2: ChainIDFormat.EIP155.format(chainId: chainId),
      data: normalizedData(params.data),
      from: params.from,
      gasLimit: gasLimit,
      maxFeePerGas: gasPrice,
      maxPriorityFeePerGas: gasPrice,
      nonce: nonce,
      sponsor: false,
      to: params.to,
      value: decimalString(fromHex: params.value)
    )
  }

  private func resolveEthereumWalletAddress(from wallets: [Wallet]) -> String? {
    wallets
      .flatMap(\.accounts)
      .first(where: { $0.addressFormat == .address_format_ethereum })?
      .address
  }

  private func draftTransaction(
    from activity: v1Activity,
    expectedChainId: Int
  ) -> ActivityDraft? {
    guard let intent = activity.intent.ethSendTransactionIntent else {
      return nil
    }

    let chainId = chainId(from: intent.caip2)
    guard chainId == expectedChainId else {
      return nil
    }

    let seconds = Double(activity.createdAt.seconds) ?? 0
    let nanos = Double(activity.createdAt.nanos) ?? 0

    return ActivityDraft(
      id: activity.id,
      timestamp: seconds + nanos / 1_000_000_000,
      from: intent.from,
      to: intent.to,
      value: intent.value,
      data: intent.data,
      chainId: chainId,
      sendTransactionStatusId: activity.result.ethSendTransactionResult?.sendTransactionStatusId
    )
  }

  private func resolveTransactionHash(
    sendTransactionStatusId: String?
  ) async throws -> String? {
    guard let sendTransactionStatusId else {
      return nil
    }

    let status = try await sessions.executeRead { session, client in
      try await client.getSendTransactionStatus(
        TGetSendTransactionStatusBody(
          organizationId: session.organizationId,
          sendTransactionStatusId: sendTransactionStatusId
        )
      )
    }
    return status.eth?.txHash
  }

  private func pollForTransactionHash(
    sendTransactionStatusId: String
  ) async throws -> String {
    for attempt in 0..<Self.AdapterConstants.defaultPollingAttempts {
      // Session-guarded per poll: a session expiring mid-poll refreshes instead of aborting a
      // transaction that was already submitted. If the session dies for good, the status id
      // must survive — losing it here would invite a duplicate send after re-auth. The expiry
      // hook has already fired by then.
      let status: TGetSendTransactionStatusResponse
      do {
        status = try await sessions.executeRead { session, client in
          try await client.getSendTransactionStatus(
            TGetSendTransactionStatusBody(
              organizationId: session.organizationId,
              sendTransactionStatusId: sendTransactionStatusId
            )
          )
        }
      } catch let error as RainError where error == .tokenExpired {
        throw RainError.transactionPending(statusId: sendTransactionStatusId)
      }

      if let txHash = status.eth?.txHash, !txHash.isEmpty {
        return txHash
      }

      if let failure = Self.sendFailure(
        from: status, fallbackMessage: "Turnkey transaction submission failed"
      ) {
        throw failure
      }

      if attempt + 1 < Self.AdapterConstants.defaultPollingAttempts {
        try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
      }
    }

    // A poll timeout is not a failure: Turnkey accepted the submission and the transaction may
    // still confirm. Carrying the status id lets the host resume polling instead of resending,
    // which would risk a duplicate transfer.
    throw RainError.transactionPending(statusId: sendTransactionStatusId)
  }

  private func isNativeAsset(_ balance: v1AssetBalance, caip2: String) -> Bool {
    guard let caip19 = balance.caip19 else {
      return false
    }

    return caip19.hasPrefix("\(caip2)/slip44:")
  }

  private func tokenAddress(from caip19: String, caip2: String) -> String? {
    // EVM tokens use the `erc20` asset namespace; Solana SPL tokens use `token`.
    let prefixes = ["\(caip2)/erc20:", "\(caip2)/token:"]
    guard prefixes.contains(where: { caip19.hasPrefix($0) }) else {
      return nil
    }

    let address = String(caip19.split(separator: ":").last ?? "")
    return address.isEmpty ? nil : address
  }

  private func
    chainId(from caip2: String) -> Int {
    Int(caip2.split(separator: ":").last ?? "") ?? 0
  }

  private func rpcCallForHex(
    chainId: Int,
    method: String,
    params: [Any]
  ) async throws -> String {
    let rpcURL = try getRpcURL(chainId: chainId)
    do {
      return try await jsonRpcClient.callForHexResult(rpcUrl: rpcURL, method: method, params: params)
    } catch RainError.invalidRpcUrl(let url) {
      // Upgrade to invalidConfig with the chainId we have on hand.
      throw RainError.invalidConfig(details: "Invalid RPC URL for chainId=\(chainId): \(url)")
    }
  }

  private func rpcTransactionObject(from params: WalletTransactionParams) -> [String: Any] {
    var transaction: [String: Any] = [
      "from": params.from,
      "to": params.to,
      "value": params.value
    ]

    if !params.data.isEmpty {
      transaction["data"] = params.data
    }

    return transaction
  }

  private func getRpcURL(chainId: Int) throws -> String {
    guard let networkConfig = networkConfigsByChainId[chainId] else {
      throw RainError.invalidConfig(details: "No RPC endpoint configured for chainId=\(chainId)")
    }

    return networkConfig.rpcUrl
  }

  /// Classifies a terminal Turnkey send status. A status that carries a decoded on-chain revert
  /// — an EVM `revertChain` (top-level or under `error.eth`) or Solana failure details — is the
  /// program/contract rejecting the transaction, i.e. exactly what a self-paid send's dry run
  /// would have caught before signing. Sponsored sends skip that dry run, so this is where the
  /// revert surfaces; it maps to `transactionSimulationFailed` so core's withdrawal path yields
  /// `withdrawalRevertedByNetwork` (RAIN_405) for both, instead of a generic `providerError`.
  /// Any other failure (rejected by Turnkey, unknown) stays `providerError`. `nil` = not failed.
  static func sendFailure(
    from status: TGetSendTransactionStatusResponse, fallbackMessage: String
  ) -> RainError? {
    let normalized = status.txStatus.uppercased()
    let failed = normalized.contains("FAILED") || normalized.contains("REJECTED")
      || status.txError != nil || status.error?.message != nil
    guard failed else { return nil }

    let message = status.txError ?? status.error?.message ?? fallbackMessage
    let underlying = NSError(
      domain: "TurnkeyTransaction", code: -1, userInfo: [NSLocalizedDescriptionKey: message]
    )
    if Self.carriesOnChainRevert(status.error) {
      return .transactionSimulationFailed(underlying: underlying)
    }
    return .providerError(underlying: underlying)
  }

  private static func carriesOnChainRevert(_ error: v1TxError?) -> Bool {
    guard let error else { return false }
    if let chain = error.revertChain, !chain.isEmpty { return true }
    if let chain = error.eth?.revertChain, !chain.isEmpty { return true }
    if let solana = error.solana {
      return solana.transactionErrorJson != nil || solana.rpcMessage != nil
        || solana.logs?.isEmpty == false
    }
    return false
  }

  private func decimalStringToDecimal(
    balance: String?,
    decimals: Int
  ) -> Decimal {
    guard let balance, !balance.isEmpty else {
      return 0
    }

    let value = NSDecimalNumber(string: balance)
    guard value != NSDecimalNumber.notANumber else {
      return 0
    }
    let divisor = NSDecimalNumber(
      mantissa: 1,
      exponent: Int16(decimals),
      isNegative: false
    )

    return value.dividing(by: divisor).decimalValue
  }

  private func decimalString(fromHex hex: String) -> String {
    guard let value = BigUInt(hex.strippingHexPrefix, radix: 16) else {
      return "0"
    }

    return value.description
  }

  private func normalizedData(_ data: String) -> String {
    if data.isEmpty {
      return "0x"
    }

    return data
  }

  private static func iso8601String(from timestamp: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
  }

  private static func ethereumSignatureHex(from signature: SignRawPayloadResult) -> String {
    let r = normalizeHexComponent(signature.r, length: 64)
    let s = normalizeHexComponent(signature.s, length: 64)
    let v = String(format: "%02x", normalizedRecoveryId(signature.v))

    return "0x\(r)\(s)\(v)"
  }

  private static func normalizeHexComponent(_ value: String, length: Int) -> String {
    let clean = value
      .lowercased()
      .replacingOccurrences(of: "0x", with: "")
    if clean.count >= length {
      return String(clean.suffix(length))
    }

    return String(repeating: "0", count: length - clean.count) + clean
  }

  private static func normalizedRecoveryId(_ value: String) -> Int {
    let clean = value.lowercased()
    let parsedValue: Int?

    if clean.hasPrefix("0x") {
      parsedValue = Int(clean.dropFirst(2), radix: 16)
    } else if let decimal = Int(clean) {
      parsedValue = decimal
    } else {
      parsedValue = Int(clean, radix: 16)
    }

    guard let parsedValue else {
      return 27
    }

    return parsedValue >= 27 ? parsedValue : parsedValue + 27
  }
}
