import Foundation
import PrivySDK
import RainCore

/// Wrapper around the Privy SDK encapsulating all Privy interactions — the custody seam.
///
/// Privy owns signing and broadcasting via its EIP-1193 embedded-wallet provider; balance / fee
/// reads run through ``PrivyRpcClient`` instead. Authentication and `PrivySdk.initialize(...)`
/// happen in the host app, so this only ever consumes an already-authenticated `Privy` singleton.
///
/// An `actor` for two reasons:
///  1. **Race-safe address resolution** — concurrent first-access callers share a single
///     in-flight resolution.
///  2. **Serialized sends** — Privy's provider is stateful about the active chain
///     (`switchChain` mutates it before `request` broadcasts), and actors are re-entrant at
///     `await` points, so the switch+broadcast pair runs under an explicit async lock.
actor PrivyManager {
  private let source: any PrivyWalletSource
  /// Guards every Privy call: auth-state check, transient backoff, typed session death.
  /// `nil` (test default) leaves calls unguarded.
  private let sessions: PrivySessionCoordinator?

  /// Once resolved, the embedded-wallet address is stable for the manager's lifetime.
  private var cachedAddress: String?
  /// In-flight resolution shared by concurrent first callers (resolve-once).
  private var addressResolution: Task<String, Error>?

  /// Same pair for the Solana account — a separate wallet in Privy, so a separate cache. The
  /// account itself is cached (not just its address) since sends sign through it.
  private var cachedSolanaAccount: (any PrivySolanaAccount)?
  private var solanaAccountResolution: Task<any PrivySolanaAccount, Error>?

  // MARK: async lock (send serialization)
  private var sendLocked = false
  private var sendWaiters: [CheckedContinuation<Void, Never>] = []

  init(source: any PrivyWalletSource, sessions: PrivySessionCoordinator? = nil) {
    self.source = source
    self.sessions = sessions
  }

  init(privy: any Privy, sessions: PrivySessionCoordinator? = nil) {
    self.init(source: LivePrivyWalletSource(privy: privy), sessions: sessions)
  }

  /// Bumped on every eviction so a resolution that was already in flight when the session
  /// died cannot write the dead session's account back into the cache.
  private var evictionEpoch = 0

  /// Drops the cached accounts and in-flight resolutions. Called on session death so a later
  /// login as a different user can never sign with the previous user's accounts.
  func evictCachedAccounts() {
    evictionEpoch += 1
    cachedAddress = nil
    addressResolution = nil
    cachedSolanaAccount = nil
    solanaAccountResolution = nil
  }

  // MARK: - Address

  /// The signing wallet's address, resolved once and cached. `override` (when non-empty) wins and
  /// is returned without a Privy round-trip.
  func address(override: String?) async throws -> String {
    if let override, !override.isEmpty {
      return override
    }
    if let cachedAddress {
      return cachedAddress
    }
    if let addressResolution {
      return try await addressResolution.value
    }
    let epoch = evictionEpoch
    let task = Task { [source, sessions] in
      try await Self.guardedRead(sessions) {
        try await Self.resolveWallet(source: source, override: nil).address
      }
    }
    addressResolution = task
    do {
      let resolved = try await task.value
      // Cache only while no eviction happened mid-flight — this result may belong to a
      // session that just died.
      if evictionEpoch == epoch {
        cachedAddress = resolved
      }
      return resolved
    } catch {
      // Allow a later caller to retry (e.g. wallet created after this failed probe).
      if evictionEpoch == epoch {
        addressResolution = nil
      }
      throw error
    }
  }

  /// The embedded Solana account's base58 address. Never falls back to the Ethereum address (or
  /// its override) — that would read the wrong account on Solana.
  func solanaAddress() async throws -> String {
    try await solanaAccount().address
  }

  /// The embedded Solana account, resolved once and cached.
  private func solanaAccount() async throws -> any PrivySolanaAccount {
    if let cachedSolanaAccount {
      return cachedSolanaAccount
    }
    if let solanaAccountResolution {
      return try await solanaAccountResolution.value
    }
    let epoch = evictionEpoch
    let task = Task { [source, sessions] in
      try await Self.guardedRead(sessions) {
        try await Self.resolveSolanaAccount(source: source)
      }
    }
    solanaAccountResolution = task
    do {
      let resolved = try await task.value
      // Cache only while no eviction happened mid-flight (see `address(override:)`).
      if evictionEpoch == epoch {
        cachedSolanaAccount = resolved
      }
      return resolved
    } catch {
      // Allow a later caller to retry (e.g. Solana wallet created after this failed probe).
      if evictionEpoch == epoch {
        solanaAccountResolution = nil
      }
      throw error
    }
  }

  // MARK: - Sign

  /// Signs EIP-712 typed data via `eth_signTypedData_v4`. Returns the 0x-prefixed signature.
  /// Signing takes no chain state, so it is not serialized with sends.
  func signTypedData(walletAddress: String, typedDataJson: String) async throws -> String {
    try await Self.guardedWrite(sessions) { [source] in
      let wallet = try await Self.resolveWallet(source: source, override: walletAddress)
      let rpcRequest = EthereumRpcRequest(
        method: "eth_signTypedData_v4",
        params: [wallet.address, typedDataJson]
      )
      return try await Self.request(wallet: wallet, rpcRequest)
    }
  }

  // MARK: - Send

  /// Broadcasts a transaction via `eth_sendTransaction`, returning the tx hash. Points Privy at
  /// Rain's configured RPC for `chainId` via `switchChain` first; the wallet fills any omitted
  /// gas / nonce. The switch + broadcast run under the async lock so concurrent sends serialize.
  func sendTransaction(
    walletAddress: String,
    rpcUrl: String,
    chainId: Int,
    transaction: EthereumRpcRequest.UnsignedEthTransaction
  ) async throws -> String {
    try await sessions?.preflight()
    let wallet: any PrivyEthereumSigner
    do {
      wallet = try await Self.resolveWallet(source: source, override: walletAddress)
    } catch {
      // A user gone at resolve time is a session death too: classify so the hook fires.
      throw sessions?.classifyFailure(error) ?? error
    }
    let rpcRequest = try EthereumRpcRequest.ethSendTransaction(transaction: transaction)

    await acquireSendLock()
    do {
      await wallet.switchChain(chainId: chainId, rpcUrl: rpcUrl)
      let hash = try await Self.request(wallet: wallet, rpcRequest)
      releaseSendLock()
      return hash
    } catch {
      releaseSendLock()
      throw sessions?.classifyFailure(error) ?? error
    }
  }

  /// Signs and broadcasts a serialized Solana transaction, returning its signature. Not covered by
  /// the send lock: Privy takes the cluster per call, so there is no chain state to serialize.
  ///
  /// Failures bubble up raw, for the same reason as ``request(wallet:_:)``.
  func sendSolanaTransaction(
    transaction: Data,
    caip2: String,
    rpcUrl: String
  ) async throws -> String {
    try await sessions?.preflight()
    let account = try await solanaAccount()
    do {
      return try await account.signAndSendTransaction(
        transaction: transaction,
        caip2: caip2,
        rpcUrl: rpcUrl
      )
    } catch {
      if error is CancellationError { throw error }
      RainLogger.error("Rain SDK: Privy Solana send failed: \(error)")
      throw sessions?.classifyFailure(error) ?? error
    }
  }

  // MARK: - Transactions

  /// Fetches one page of transaction history for the signing wallet via Privy's indexer.
  ///
  /// Failures bubble up raw for the same reason as ``request(wallet:_:)``: pre-wrapping would
  /// bypass error mapping downstream.
  func getTransactions(
    walletAddress: String?,
    params: GetTransactionsParams
  ) async throws -> PrivyTransactionsPage {
    try await Self.guardedRead(sessions) { [source] in
      let wallet = try await Self.resolveWallet(source: source, override: walletAddress)
      return try await wallet.getTransactions(params)
    }
  }

  /// One page of Solana history for the embedded Solana account (vs. the Ethereum one).
  func getSolanaTransactions(params: GetTransactionsParams) async throws -> PrivyTransactionsPage {
    let account = try await solanaAccount()
    return try await Self.guardedRead(sessions) {
      try await account.getTransactions(params)
    }
  }

  // MARK: - Internals

  /// Issues an RPC request through the wallet's provider.
  ///
  /// Failures bubble up raw (only logged here): `RainError.from(underlying:)` short-circuits
  /// on any `RainError`, so pre-wrapping would bypass ``PrivyErrorMapping`` and hide
  /// user-rejection / insufficient-funds behind a generic `.providerError`.
  /// `CancellationError` is rethrown as-is.
  private static func request(
    wallet: any PrivyEthereumSigner,
    _ rpcRequest: EthereumRpcRequest
  ) async throws -> String {
    do {
      return try await wallet.request(rpcRequest)
    } catch {
      if error is CancellationError { throw error }
      RainLogger.error("Rain SDK: Privy RPC request failed for \(rpcRequest.method): \(error)")
      throw error
    }
  }

  /// Routes through the coordinator's read guard when one is attached; plain call otherwise.
  private static func guardedRead<T>(
    _ sessions: PrivySessionCoordinator?,
    _ block: () async throws -> T
  ) async throws -> T {
    guard let sessions else { return try await block() }
    return try await sessions.executeRead(block)
  }

  /// Routes through the coordinator's write guard when one is attached; plain call otherwise.
  private static func guardedWrite<T>(
    _ sessions: PrivySessionCoordinator?,
    _ block: () async throws -> T
  ) async throws -> T {
    guard let sessions else { return try await block() }
    return try await sessions.executeWrite(block)
  }

  /// Resolves the embedded Ethereum wallet to sign with. Uses `override` when supplied, otherwise
  /// the user's first embedded Ethereum wallet.
  private static func resolveWallet(
    source: any PrivyWalletSource,
    override: String?
  ) async throws -> any PrivyEthereumSigner {
    guard let wallets = await source.embeddedEthereumWallets() else {
      throw RainError.tokenExpired
    }
    guard !wallets.isEmpty else {
      throw RainError.walletUnavailable(details: "Privy user has no embedded wallet for this chain")
    }
    guard let override, !override.isEmpty else {
      return wallets[0]
    }
    guard let match = wallets.first(where: {
      $0.address.caseInsensitiveCompare(override) == .orderedSame
    }) else {
      throw RainError.walletUnavailable(details: "Privy user has no embedded wallet for this chain")
    }
    return match
  }

  /// Resolves the user's first embedded Solana account. `nil` = no session; `[]` = no Solana
  /// wallet created yet (`user.createSolanaWallet()` in the host app).
  private static func resolveSolanaAccount(
    source: any PrivyWalletSource
  ) async throws -> any PrivySolanaAccount {
    guard let wallets = await source.embeddedSolanaWallets() else {
      throw RainError.tokenExpired
    }
    guard let wallet = wallets.first else {
      throw RainError.walletUnavailable(details: "Privy user has no embedded wallet for this chain")
    }
    return wallet
  }

  // MARK: - Async lock

  /// Acquires the send lock, suspending until it is free (fair FIFO).
  private func acquireSendLock() async {
    if !sendLocked {
      sendLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      sendWaiters.append(continuation)
    }
  }

  /// Releases the send lock, handing it to the next waiter (if any).
  private func releaseSendLock() {
    if sendWaiters.isEmpty {
      sendLocked = false
    } else {
      sendWaiters.removeFirst().resume()
    }
  }
}
