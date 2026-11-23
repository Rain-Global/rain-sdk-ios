import Foundation
import PrivySDK
import RainCore
import Web3

/// Privy-backed `WalletProvider`.
///
/// Custody (signing, broadcasting) goes through Privy's EIP-1193 embedded wallet via
/// ``PrivyManager``; balance and fee reads run through ``PrivyRpcClient`` against Rain's
/// configured RPC, with metadata resolved by `tokenStore`.
///
/// Chain families dispatch on `RainChain.isSolana(_:)`: Solana clusters use the embedded Solana
/// account, with reads and transfer composition (native SOL and SPL alike) going through core's
/// ``RainSolanaSupport`` — Privy only signs and broadcasts what it composes. Everything else is
/// EVM; the EVM-shaped writes (`sendTransaction`, fee estimate, typed-data) stay unsupported on
/// Solana.
///
/// Transaction history comes from Privy's indexer via the wallet's `getTransactions` (TEE wallets
/// only, and only on chains Privy indexes); unsupported chains return an empty list, matching the
/// pre-indexer behavior. Solana history reads the embedded Solana account's own indexer entries —
/// Privy's server-side chain enum covers only mainnet, so devnet / testnet return empty like an
/// unindexed EVM chain.
internal final class PrivyWalletProvider: WalletProvider, RainTypedDataSignerProvider, RainTransactionFeeEstimatingProvider, RainSolanaTransfersProvider, @unchecked Sendable {
  /// Upper bound on simultaneous per-token balance RPC calls in ``getBalances(chainId:)``. Without
  /// it a large token registry would fan out one connection per token at once.
  private static let maxConcurrentBalanceReads = 8

  private let manager: PrivyManager
  private let rpcEndpoints: [Int: String]
  private let tokenStore: TokenMetadataStore
  private let walletAddressOverride: String?
  private let rpcClient: PrivyRpcClient
  private let solanaSupport: RainSolanaSupport

  internal init(
    manager: PrivyManager,
    rpcEndpoints: [Int: String],
    tokenStore: TokenMetadataStore,
    solanaSupport: RainSolanaSupport,
    walletAddressOverride: String? = nil,
    rpcClient: PrivyRpcClient = PrivyRpcClient()
  ) {
    self.manager = manager
    self.rpcEndpoints = rpcEndpoints
    self.tokenStore = tokenStore
    self.solanaSupport = solanaSupport
    self.walletAddressOverride = walletAddressOverride
    self.rpcClient = rpcClient
  }

  // MARK: - Address

  /// The embedded Ethereum address; prefer ``getAddress(chainId:)`` when the chain may be Solana.
  func address() async throws -> String {
    try await manager.address(override: walletAddressOverride)
  }

  func getAddress(chainId: Int) async throws -> String {
    RainChain.isSolana(chainId)
      ? try await manager.solanaAddress()
      : try await address()
  }

  // MARK: - Send

  func sendTransaction(
    chainId: Int,
    params: WalletTransactionParams
  ) async throws -> String {
    try Self.requireEVM(chainId: chainId, operation: "sendTransaction")
    let rpcUrl = try rpcUrl(for: chainId)

    // Simulate via eth_call before broadcasting to catch failures (revert / insufficient funds)
    // up front — the node validates it for free.
    do {
      _ = try await rpcClient.callForHexResult(
        rpcUrl: rpcUrl,
        method: "eth_call",
        params: [rpcTransactionObject(from: params), "latest"],
        purpose: .simulation
      )
    } catch {
      if error is CancellationError { throw error }
      // Node errors the RPC client already classified (insufficient funds, simulation failure)
      // surface as themselves; anything else is a simulation failure.
      if let rainError = error as? RainError {
        switch rainError {
        case .insufficientFunds, .transactionSimulationFailed:
          throw rainError
        default:
          break
        }
      }
      throw RainError.transactionSimulationFailed(underlying: error)
    }

    let transaction = EthereumRpcRequest.UnsignedEthTransaction(
      from: params.from,
      to: params.to,
      data: normalizedData(params.data),
      value: .hexadecimalNumber(params.value.isEmpty ? "0x0" : params.value),
      chainId: .int(chainId)
    )

    return try await manager.sendTransaction(
      walletAddress: params.from,
      rpcUrl: rpcUrl,
      chainId: chainId,
      transaction: transaction
    )
  }

  // MARK: - Solana send

  /// Signs and broadcasts a native SOL transfer through Privy, returning the signature.
  ///
  /// Core composes the unsigned transaction (fresh blockhash + System Program transfer) and Privy
  /// signs and broadcasts it against the cluster Rain is configured with. The signature is
  /// returned as soon as Privy accepts the broadcast, not once confirmed — same contract as the
  /// EVM path returning a tx hash.
  func sendSolanaNative(
    chainId: Int,
    to toAddress: String,
    amount: Decimal
  ) async throws -> String {
    let from = try await manager.solanaAddress()
    let unsigned = try await solanaSupport.composeNativeTransfer(
      chainId: chainId, from: from, to: toAddress, amount: amount
    )
    return try await broadcast(chainId: chainId, unsigned: unsigned)
  }

  /// Signs and broadcasts an SPL token transfer through Privy.
  ///
  /// Composition and every preflight (mint resolution, token-account derivation/creation, balance
  /// and fee checks, simulation) live in core's composer, so Turnkey and Privy cannot drift.
  /// `decimals` is deliberately unread — the composer reads the mint's own scale from the chain,
  /// which `TransferChecked` then enforces.
  func sendSolanaSPLToken(
    chainId: Int,
    mintAddress: String,
    to toAddress: String,
    amount: Decimal,
    decimals: Int
  ) async throws -> String {
    let from = try await manager.solanaAddress()
    let unsigned = try await solanaSupport.composeSPLTransfer(
      chainId: chainId,
      from: from,
      mintAddress: mintAddress,
      to: toAddress,
      amount: amount
    )
    return try await broadcast(chainId: chainId, unsigned: unsigned)
  }

  /// Signs and broadcasts a transaction core composed (a collateral withdrawal). The bytes are
  /// signed as handed over — rebuilding them would invalidate the coordinator signature they embed.
  func signAndSendSolanaTransaction(
    chainId: Int,
    unsigned: UnsignedSolanaTransfer
  ) async throws -> String {
    try await broadcast(chainId: chainId, unsigned: unsigned)
  }

  /// Hands a composed transfer to Privy for signing and broadcast on the cluster Rain reads from.
  private func broadcast(
    chainId: Int,
    unsigned: UnsignedSolanaTransfer
  ) async throws -> String {
    let (caip2, rpcUrl) = try solanaCluster(for: chainId)
    return try await manager.sendSolanaTransaction(
      transaction: unsigned.transaction,
      caip2: caip2,
      rpcUrl: rpcUrl
    )
  }

  // MARK: - Sign

  func signTypedData(
    chainId: Int,
    walletAddress: String,
    typedData: String
  ) async throws -> String {
    try Self.requireEVM(chainId: chainId, operation: "signTypedData")
    return try await manager.signTypedData(walletAddress: walletAddress, typedDataJson: typedData)
  }

  // MARK: - Fees

  func estimateTransactionFee(
    chainId: Int,
    walletAddress: String,
    params: WalletTransactionParams
  ) async throws -> Decimal {
    try Self.requireEVM(chainId: chainId, operation: "estimateTransactionFee")
    let rpcUrl = try rpcUrl(for: chainId)
    let gasLimitHex = try await rpcClient.callForHexResult(
      rpcUrl: rpcUrl,
      method: "eth_estimateGas",
      params: [rpcTransactionObject(from: params)],
      purpose: .simulation
    )
    let gasPriceHex = try await rpcClient.callForHexResult(
      rpcUrl: rpcUrl,
      method: "eth_gasPrice",
      params: []
    )
    // Exact wei math: multiply as BigUInt, divide to native units as Decimal.
    let gasLimit = try EthereumConverter.parseHexToBigUIntStrict(gasLimitHex)
    let gasPriceWei = try EthereumConverter.parseHexToBigUIntStrict(gasPriceHex)
    return EthereumConverter.baseUnitsToDecimal(
      gasLimit * gasPriceWei,
      decimals: Constants.ERC20.defaultDecimals
    )
  }

  // MARK: - Balances

  func getBalance(
    chainId: Int,
    token: Token
  ) async throws -> Balance {
    if RainChain.isSolana(chainId) {
      // Native SOL, or an SPL mint read from its token account — never the EVM path. Registered
      // metadata is passed through for naming: SPL mints carry no symbol on chain.
      var registered: TokenInfo?
      if case .contract(let mint) = token {
        registered = await tokenStore.registeredTokens(for: chainId).first { $0.address == mint }
      }
      return try await solanaSupport.getBalance(
        chainId: chainId,
        walletAddress: try await manager.solanaAddress(),
        token: token,
        tokenInfo: registered
      )
    }

    let walletAddress = try await address()
    switch token {
    case .native:
      return try await fetchNativeBalance(chainId: chainId, walletAddress: walletAddress)
    case .contract(let contractAddress):
      return try await fetchContractBalance(
        chainId: chainId,
        walletAddress: walletAddress,
        address: contractAddress
      )
    }
  }

  func getBalances(
    chainId: Int
  ) async throws -> [Balance] {
    // Solana: native SOL plus every SPL token the wallet holds, discovered from the chain — there
    // is no registry to enumerate. Registered entries only supply naming.
    if RainChain.isSolana(chainId) {
      return try await solanaSupport.getBalances(
        chainId: chainId,
        walletAddress: try await manager.solanaAddress(),
        tokens: await tokenStore.registeredTokens(for: chainId)
      )
    }

    let walletAddress = try await address()

    // Native is essential: its failure propagates. Per-token reads are best-effort — a single
    // bad / failing contract must not drop the whole list, so each is wrapped and skipped on
    // failure. Concurrency is capped by a sliding window over the task group.
    let native = try await fetchNativeBalance(chainId: chainId, walletAddress: walletAddress)
    let tokens = await tokenStore.registeredTokens(for: chainId)

    var output: [Balance] = [native]
    guard !tokens.isEmpty else { return output }

    let contractBalances = await withTaskGroup(of: Balance?.self) { group in
      var nextIndex = 0
      let window = min(Self.maxConcurrentBalanceReads, tokens.count)
      while nextIndex < window {
        let address = tokens[nextIndex].address
        group.addTask { [self] in
          await tryFetchContractBalance(chainId: chainId, walletAddress: walletAddress, address: address)
        }
        nextIndex += 1
      }

      var collected: [Balance] = []
      for await result in group {
        if let balance = result, balance.rawAmount > 0 {
          collected.append(balance)
        }
        if nextIndex < tokens.count {
          let address = tokens[nextIndex].address
          group.addTask { [self] in
            await tryFetchContractBalance(chainId: chainId, walletAddress: walletAddress, address: address)
          }
          nextIndex += 1
        }
      }
      return collected
    }

    output.append(contentsOf: contractBalances)
    return output
  }

  /// Best-effort single contract balance: logs and returns `nil` on failure so one token never
  /// cancels the batch.
  private func tryFetchContractBalance(
    chainId: Int,
    walletAddress: String,
    address: String
  ) async -> Balance? {
    do {
      return try await fetchContractBalance(chainId: chainId, walletAddress: walletAddress, address: address)
    } catch {
      RainLogger.warning("Rain SDK: Privy balance read failed for token=\(address) chainId=\(chainId); skipping: \(error)")
      return nil
    }
  }

  private func fetchNativeBalance(chainId: Int, walletAddress: String) async throws -> Balance {
    let rpcUrl = try rpcUrl(for: chainId)
    let hex = try await rpcClient.callForHexResult(
      rpcUrl: rpcUrl,
      method: "eth_getBalance",
      params: [walletAddress, "latest"]
    )
    let native = await tokenStore.nativeCurrency(for: chainId)
    return Balance(
      token: .native,
      chainId: chainId,
      rawAmount: try EthereumConverter.parseHexToBigUIntStrict(hex),
      decimals: native.decimals,
      symbol: native.symbol,
      name: native.name
    )
  }

  private func fetchContractBalance(
    chainId: Int,
    walletAddress: String,
    address: String
  ) async throws -> Balance {
    let rpcUrl = try rpcUrl(for: chainId)
    let info = await tokenStore.tokenInfo(chainId: chainId, address: address)
    let callData = Multicall3.encodeBalanceOf(address: walletAddress)
    let callObject: [String: Any] = ["to": address, "data": callData]
    let hex = try await rpcClient.callForHexResult(
      rpcUrl: rpcUrl,
      method: "eth_call",
      params: [callObject, "latest"]
    )
    return Balance(
      token: .contract(address: address),
      chainId: chainId,
      rawAmount: try EthereumConverter.parseHexToBigUIntStrict(hex),
      decimals: info.decimals,
      symbol: info.symbol,
      name: info.name
    )
  }

  // MARK: - Transactions

  /// Default rows returned by `getTransactions` when the caller passes no limit (parity with
  /// Turnkey).
  private static let defaultTransactionLimit = 10
  /// Privy's server-side maximum page size for its transactions endpoint.
  private static let maxTransactionsPageSize = 100
  /// Privy's server-side maximum number of asset/token filters per request.
  private static let maxTransactionFiltersPerRequest = 10
  private static let solanaNativeAsset = "sol"
  /// Min base58 length separating a mint from a named asset in a row's `asset` field.
  private static let solanaMinAddressLength = 32

  /// Wallet history from Privy's transaction indexer.
  ///
  /// Privy's endpoint requires exactly one of an `assets` or `tokens` filter per request, so
  /// full history is assembled from one native-asset query plus token-address queries over the
  /// registered tokens (chunked to the server's 10-filter cap). Every query is essential: any
  /// failure (native or token chunk) fails the whole call rather than returning silently
  /// partial history, bubbling up raw so ``PrivyErrorMapping`` / `RainError.from` classify
  /// it at the SDK boundary. Privy paginates by cursor while the SDK contract is limit/offset,
  /// so each query collects pages until `offset + limit` rows are gathered (or history is
  /// exhausted); the merged rows are deduped, sorted by `createdAt` per `order` (newest first
  /// by default, matching Turnkey) and sliced. Chains Privy does not index (e.g. Base Sepolia)
  /// return an empty list rather than failing, preserving the previous always-empty behavior.
  ///
  /// Solana clusters read the embedded Solana account's own indexer entries, mainnet only (Privy
  /// has no devnet / testnet slug); other clusters return an empty list.
  func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    let needed = max((limit ?? Self.defaultTransactionLimit) + (offset ?? 0), 1)
    let collected =
      RainChain.isSolana(chainId)
      ? try await collectSolanaHistory(chainId: chainId, needed: needed)
      : try await collectEvmHistory(chainId: chainId, needed: needed)
    guard let collected else { return [] }

    var seen = Set<String>()
    let deduped = collected.filter { transaction in
      guard let key = transaction.privyTransactionId ?? transaction.transactionHash else { return true }
      return seen.insert(key).inserted
    }
    let sorted = deduped.sorted { lhs, rhs in
      switch order ?? .DESC {
      case .ASC: return lhs.createdAt < rhs.createdAt
      case .DESC: return lhs.createdAt > rhs.createdAt
      }
    }
    let sliced = sorted
      .dropFirst(offset ?? 0)
      .prefix(limit ?? needed)

    return sliced.map { Self.rainTransaction(chainId: chainId, from: $0) }
  }

  /// EVM rows across the native asset and registered tokens, or `nil` when Privy has no slug for
  /// the chain (caller returns an empty list).
  private func collectEvmHistory(chainId: Int, needed: Int) async throws -> [PrivyIndexedTransaction]? {
    guard let chain = Self.privyChain(for: chainId) else { return nil }
    let walletAddress = try await address()

    var collected = try await collectPages(needed: needed) { pageLimit, cursor in
      try await manager.getTransactions(
        walletAddress: walletAddress,
        params: GetTransactionsParams(
          chain: chain.chain, assets: [chain.nativeAsset], tokens: nil,
          limit: pageLimit, cursor: cursor
        )
      )
    }
    let tokenAddresses = await tokenStore.registeredTokens(for: chainId).map(\.address)
    for chunk in Self.chunks(tokenAddresses, size: Self.maxTransactionFiltersPerRequest) {
      collected += try await collectPages(needed: needed) { pageLimit, cursor in
        try await manager.getTransactions(
          walletAddress: walletAddress,
          params: GetTransactionsParams(
            chain: chain.chain, assets: nil, tokens: chunk, limit: pageLimit, cursor: cursor
          )
        )
      }
    }
    return collected
  }

  /// Solana rows from the Solana account's indexer, or `nil` when the cluster isn't indexed
  /// (Privy covers only mainnet).
  private func collectSolanaHistory(chainId: Int, needed: Int) async throws -> [PrivyIndexedTransaction]? {
    guard chainId == RainChain.solanaMainnet else { return nil }

    var collected = try await collectPages(needed: needed) { pageLimit, cursor in
      try await manager.getSolanaTransactions(
        params: GetTransactionsParams(
          chain: .solana, assets: [Self.solanaNativeAsset], tokens: nil,
          limit: pageLimit, cursor: cursor
        )
      )
    }
    let tokenAddresses = await tokenStore.registeredTokens(for: chainId).map(\.address)
    for chunk in Self.chunks(tokenAddresses, size: Self.maxTransactionFiltersPerRequest) {
      collected += try await collectPages(needed: needed) { pageLimit, cursor in
        try await manager.getSolanaTransactions(
          params: GetTransactionsParams(
            chain: .solana, assets: nil, tokens: chunk, limit: pageLimit, cursor: cursor
          )
        )
      }
    }
    return collected
  }

  /// Collects up to `needed` rows for one assets-or-tokens filter, following Privy's cursor.
  private func collectPages(
    needed: Int,
    fetch: (_ pageLimit: Int, _ cursor: String?) async throws -> PrivyTransactionsPage
  ) async throws -> [PrivyIndexedTransaction] {
    var collected: [PrivyIndexedTransaction] = []
    var cursor: String?
    repeat {
      let page = try await fetch(min(needed - collected.count, Self.maxTransactionsPageSize), cursor)
      collected.append(contentsOf: page.transactions)
      cursor = page.nextCursor
    } while cursor != nil && collected.count < needed
    return collected
  }

  private static func chunks<T>(_ array: [T], size: Int) -> [[T]] {
    stride(from: 0, to: array.count, by: size).map {
      Array(array[$0..<min($0 + size, array.count)])
    }
  }

  private static func rainTransaction(
    chainId: Int,
    from transaction: PrivyIndexedTransaction
  ) -> RainTransaction {
    let details = transaction.details
    // `asset` is a named asset ("eth"/"sol"/"usdc") or a token address. EVM addresses are
    // 0x-prefixed; a Solana mint is base58, told from a named asset by length.
    let isSolana = RainChain.isSolana(chainId)
    let assetIsAddress: Bool = {
      guard let asset = details?.asset else { return false }
      return isSolana ? asset.count >= Self.solanaMinAddressLength : asset.hasPrefix("0x")
    }()
    let value = details.flatMap { detail -> Decimal? in
      guard let raw = AmountHelpers.strictDecimal(from: detail.rawValue) else { return nil }
      return NSDecimalNumber(decimal: raw)
        .multiplying(byPowerOf10: Int16(-detail.rawValueDecimals))
        .decimalValue
    }
    return RainTransaction(
      hash: transaction.transactionHash
        ?? transaction.userOperationHash
        ?? transaction.privyTransactionId
        ?? "",
      uniqueId: transaction.privyTransactionId ?? transaction.transactionHash,
      timestamp: Date(timeIntervalSince1970: Double(transaction.createdAt) / 1000)
        .formatted(.iso8601),
      from: details?.sender ?? "",
      to: details?.recipient,
      value: value,
      asset: assetIsAddress ? nil : details?.asset,
      tokenAddress: assetIsAddress ? details?.asset : nil,
      rawValue: assetIsAddress ? details?.rawValue : nil,
      decimals: assetIsAddress ? details?.rawValueDecimals : nil,
      category: assetIsAddress ? (isSolana ? .token : .erc20) : .external,
      chainId: chainId,
      metadata: RainTransaction.Metadata(
        caip2: transaction.caip2,
        status: transaction.status,
        sponsored: transaction.sponsored,
        privyTransactionId: transaction.privyTransactionId,
        userOperationHash: transaction.userOperationHash,
        type: details?.type,
        displayValues: details.flatMap { $0.displayValues.isEmpty ? nil : $0.displayValues }
      )
    )
  }

  /// The `TransactionChain` and native-asset filter name Privy's indexer accepts for `chainId`,
  /// or `nil` when the chain is not indexed (verified against the endpoint's server-side enum:
  /// ethereum, arbitrum, avalanche, base, bsc, tempo, linea, optimism, polygon, solana, sepolia).
  /// Privy identifies chains by slug, not chain id; when Privy adds a slug with no SDK case yet
  /// (e.g. a testnet), map it here via `TransactionChain.custom(_:)`.
  private static func privyChain(for chainId: Int) -> (chain: TransactionChain, nativeAsset: String)? {
    switch chainId {
    case 1: return (.ethereum, "eth")
    case 10: return (.optimism, "eth")
    case 56: return (.bsc, "bnb")
    case 137: return (.polygon, "pol")
    case 8453: return (.base, "eth")
    case 42161: return (.arbitrum, "eth")
    case 43114: return (.avalanche, "avax")
    case 59144: return (.linea, "eth")
    case 11155111: return (.sepolia, "eth")
    case 84532: return (.custom("base_sepolia"), "eth")
    default: return nil
    }
  }

  // MARK: - Helpers

  /// Rejects Solana chain ids on the EVM-only write paths. Without it the call goes out as
  /// `eth_*` to a Solana node, which answers `-32601` and surfaces as an opaque RAIN_502.
  private static func requireEVM(chainId: Int, operation: String) throws {
    guard RainChain.isSolana(chainId) else { return }
    throw RainError.invalidConfig(
      details: "Privy provider does not support \(operation) on Solana; use sendNative for SOL transfers"
    )
  }

  /// CAIP-2 + RPC URL Privy broadcasts to, so it uses the same node Rain reads from.
  private func solanaCluster(for chainId: Int) throws -> (caip2: String, rpcUrl: String) {
    guard let caip2 = RainChain.solanaCaip2(for: chainId) else {
      throw RainError.invalidConfig(details: "Not a known Solana chainId: \(chainId)")
    }
    return (caip2, try rpcUrl(for: chainId))
  }

  private func rpcUrl(for chainId: Int) throws -> String {
    guard let rpcUrl = rpcEndpoints[chainId], !rpcUrl.isEmpty else {
      throw RainError.invalidConfig(details: "No RPC endpoint configured for chainId=\(chainId)")
    }
    return rpcUrl
  }

  /// Builds an `eth_call` / `eth_estimateGas` transaction object, omitting empty `data`.
  private func rpcTransactionObject(from params: WalletTransactionParams) -> [String: Any] {
    var transaction: [String: Any] = [
      "from": params.from,
      "to": params.to,
      "value": params.value.isEmpty ? "0x0" : params.value
    ]
    if let data = normalizedData(params.data) {
      transaction["data"] = data
    }
    return transaction
  }

  /// Normalizes calldata for Privy: `nil` for an empty / `"0x"` payload, else the hex string.
  private func normalizedData(_ data: String) -> String? {
    (data.isEmpty || data == "0x") ? nil : data
  }
}
