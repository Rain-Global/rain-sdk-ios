import Foundation
import PortalSwift
import RainCore
import Web3

/// Holds the live vendor client so a session-token refresh can replace it in place.
internal final class PortalClientHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var instance: PortalRequestProtocol

  internal init(_ instance: PortalRequestProtocol) {
    self.instance = instance
  }

  internal var current: PortalRequestProtocol {
    lock.withLock { instance }
  }

  internal func replace(with next: PortalRequestProtocol) {
    lock.withLock { instance = next }
  }
}

/// Portal-based implementation of `WalletProvider`. Lives in the `RainPortal` module.
/// Every call runs through `sessions`.
internal final class PortalWalletProviderAdapter: WalletProvider, RainTypedDataSignerProvider, RainTransactionFeeEstimatingProvider, @unchecked Sendable {
  private let handle: PortalClientHandle
  private let tokenStore: TokenMetadataStore
  private let sessions: PortalSessionCoordinator

  /// Re-read per attempt so a retry after a token refresh uses the rebuilt instance.
  private var portal: PortalRequestProtocol { handle.current }

  internal convenience init(
    portal: PortalRequestProtocol,
    tokenStore: TokenMetadataStore,
    sessions: PortalSessionCoordinator = PortalSessionCoordinator()
  ) {
    self.init(handle: PortalClientHandle(portal), tokenStore: tokenStore, sessions: sessions)
  }

  internal init(
    handle: PortalClientHandle,
    tokenStore: TokenMetadataStore,
    sessions: PortalSessionCoordinator = PortalSessionCoordinator()
  ) {
    self.handle = handle
    self.tokenStore = tokenStore
    self.sessions = sessions
  }

  public func address(
  ) async throws -> String {
    try await sessions.executeRead { try await fetchAddress() }
  }

  /// Unguarded, for balance paths already inside a guarded call (nested guards would re-mint twice).
  private func fetchAddress() async throws -> String {
    let addresses = try await portal.addresses
    let eip155 = PortalNamespace.eip155
    
    guard let addr = addresses[eip155] ?? nil, !addr.isEmpty else {
      throw RainError.walletUnavailable(details: "Portal returned no wallet address for this chain")
    }
    
    return addr
  }

  public func sendTransaction(
    chainId: Int,
    params: WalletTransactionParams
  ) async throws -> String {
    try await sessions.executeWrite {
      try await performSendTransaction(chainId: chainId, params: params)
    }
  }

  private func performSendTransaction(
    chainId: Int,
    params: WalletTransactionParams
  ) async throws -> String {
    let ethParam = ETHTransactionParam(
      from: params.from,
      to: params.to,
      value: params.value,
      data: params.data
    )
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)

    // Simulate the transaction first via eth_call to catch failures (e.g. insufficient funds)
    // before broadcasting — no balance fetch needed, the node validates it for free.
    do {
      _ = try await portal.request(
        chainId: chainIdString,
        method: .eth_call,
        params: [ethParam, "latest"],
        options: nil
      )
    } catch {
      if error is CancellationError { throw error }
      if let rainError = error as? RainError { throw rainError }
      // Auth failures (401 / invalid API key) surface as .tokenExpired even here; anything
      // else that fails the pre-flight is a simulation failure.
      if let authError = PortalErrorMapping.mapAuthOrNil(error) { throw authError }
      throw RainError.transactionSimulationFailed(underlying: error)
    }

    // Read before the submit, so the UserOperation scan below has a lower bound to search from.
    let submittedFrom = await currentBlockNumber(chainIdString)

    let response = try await portal.request(
      chainId: chainIdString,
      method: .eth_sendTransaction,
      params: [ethParam],
      options: nil
    )

    guard let txHash = response.result as? String else {
      throw RainError.internalError(details: "eth_sendTransaction returned no transaction hash")
    }

    return try await minedTransactionHash(for: txHash, chainId: chainIdString, fromBlock: submittedFrom)
  }

  // MARK: - Account abstraction

  /// Where the Portal environment has Account Abstraction enabled on a chain, `eth_sendTransaction`
  /// returns a UserOperation hash rather than a transaction hash. No node has heard of that hash,
  /// so a receipt poll on it never terminates. Resolve it through the EntryPoint's
  /// `UserOperationEvent` and return the hash the operation was actually mined under, keeping the
  /// port's contract (a hash the chain can answer for) true on both kinds of chain.
  ///
  /// A plain transaction is in the mempool the moment it is submitted, so it returns on the first
  /// pass and never reaches the scan.
  private func minedTransactionHash(
    for hash: String,
    chainId: String,
    fromBlock: BigUInt?
  ) async throws -> String {
    // Without a lower bound there is nothing to scan, so Portal's hash is all this can offer.
    guard let fromBlock else { return hash }

    for attempt in 0 ..< UserOperationLookup.attempts {
      if await isKnownTransaction(hash, chainId: chainId) { return hash }

      if let event = await userOperationEvent(hash, chainId: chainId, fromBlock: fromBlock) {
        guard event.succeeded else {
          throw RainError.transactionSimulationFailed(
            underlying: UserOperationReverted(hash: hash, transactionHash: event.transactionHash)
          )
        }
        RainLogger.info("Rain SDK: UserOperation \(hash) mined in transaction \(event.transactionHash)")
        return event.transactionHash
      }

      if attempt < UserOperationLookup.attempts - 1 {
        try await Task.sleep(for: UserOperationLookup.interval)
      }
    }

    // Neither shape resolved. Return what Portal gave us rather than failing a submit that may
    // still land; the caller's own confirmation reports the timeout.
    RainLogger.warning("Rain SDK: \(hash) did not resolve to a mined transaction")
    return hash
  }

  /// Whether the chain knows this hash as a transaction, mined or pending.
  private func isKnownTransaction(_ hash: String, chainId: String) async -> Bool {
    guard let response = try? await portal.request(
      chainId: chainId,
      method: .eth_getTransactionByHash,
      params: [hash],
      options: nil
    ) else { return false }
    return (response.result as? EthTransactionResponse)?.result != nil
  }

  /// Finds the `UserOperationEvent` this hash was emitted under, if it has been included yet.
  private func userOperationEvent(
    _ hash: String,
    chainId: String,
    fromBlock: BigUInt
  ) async -> (transactionHash: String, succeeded: Bool)? {
    let filter: [String: Any] = [
      "fromBlock": "0x" + String(fromBlock, radix: 16),
      "toBlock": "latest",
      // Public RPCs reject an address-less log filter, so name every canonical EntryPoint.
      "address": UserOperationLookup.entryPoints,
      "topics": [UserOperationLookup.eventTopic, hash]
    ]
    guard let response = try? await portal.request(
      chainId: chainId,
      method: .eth_getLogs,
      params: [filter],
      options: nil
    ) else { return nil }
    guard let log = (response.result as? LogsResponse)?.result?.first,
          let transactionHash = log.transactionHash else { return nil }
    return (transactionHash, Self.userOperationSucceeded(log.data))
  }

  private func currentBlockNumber(_ chainId: String) async -> BigUInt? {
    guard let response = try? await portal.request(
      chainId: chainId,
      method: .eth_blockNumber,
      params: [],
      options: nil
    ) else { return nil }
    guard let block = BigUInt(response.hexString.dropFirst(2), radix: 16), block > 0 else { return nil }
    return block
  }

  /// `UserOperationEvent` data is `(nonce, success, actualGasCost, actualGasUsed)`. An unreadable
  /// payload counts as success: the operation was mined, and inventing a failure here would mask
  /// whatever the caller's own confirmation reads back.
  private static func userOperationSucceeded(_ data: String?) -> Bool {
    guard let data, data.hasPrefix("0x") else { return true }
    let words = data.dropFirst(2)
    guard words.count >= 128 else { return true }
    let start = words.index(words.startIndex, offsetBy: 64)
    let end = words.index(start, offsetBy: 64)
    return words[start ..< end].contains { $0 != "0" }
  }

  func signTypedData(
    chainId: Int,
    walletAddress: String,
    typedData: String
  ) async throws -> String {
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)

    let response = try await sessions.executeWrite {
      try await portal.request(
        chainId: chainIdString,
        method: .eth_signTypedData_v4,
        params: [walletAddress, typedData],
        options: nil
      )
    }

    guard let signature = response.result as? String else {
      throw RainError.internalError(details: "eth_signTypedData_v4 returned no signature")
    }

    return signature
  }

  func estimateTransactionFee(
    chainId: Int,
    walletAddress: String,
    params: WalletTransactionParams
  ) async throws -> Decimal {
    let ethParam = ETHTransactionParam(
      from: params.from,
      to: params.to,
      value: params.value,
      data: params.data
    )

    let estimateGas = try await sessions.executeRead {
      try await fetchGasData(
        chainId: chainId,
        method: .eth_estimateGas,
        address: walletAddress,
        params: [ethParam]
      )
    }
    let gasPriceWei = try await sessions.executeRead {
      try await fetchGasData(
        chainId: chainId,
        method: .eth_gasPrice,
        address: walletAddress
      )
    }

    // Exact wei math: multiply as BigUInt, divide to native units as Decimal.
    return EthereumConverter.baseUnitsToDecimal(
      estimateGas * gasPriceWei,
      decimals: Constants.ERC20.defaultDecimals
    )
  }

  public func getBalance(
    chainId: Int,
    token: Token
  ) async throws -> RainCore.Balance {
    try await sessions.executeRead {
      switch token {
      case .native:
        return try await fetchNativeBalance(chainId: chainId)
      case .contract(let address):
        return try await fetchContractBalance(chainId: chainId, address: address)
      }
    }
  }

  public func getBalances(
    chainId: Int
  ) async throws -> [RainCore.Balance] {
    try await sessions.executeRead { try await fetchBalances(chainId: chainId) }
  }

  private func fetchBalances(chainId: Int) async throws -> [RainCore.Balance] {
    let native = try await fetchNativeBalance(chainId: chainId)
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)
    let tokenBalances = try await portal.getAssets(chainIdString).tokenBalances ?? []

    var output: [RainCore.Balance] = [native]
    for entry in tokenBalances {
      guard let address = entry.metadata?.tokenAddress, !address.isEmpty else { continue }
      let info = await tokenStore.tokenInfo(chainId: chainId, address: address)
      let raw = reconstructRawAmount(entry: entry, decimals: info.decimals)
      guard raw > 0 else { continue }
      output.append(
        RainCore.Balance(
          token: .contract(address: address),
          chainId: chainId,
          rawAmount: raw,
          decimals: info.decimals,
          symbol: info.symbol ?? entry.symbol,
          name: info.name ?? entry.name
        )
      )
    }
    return output
  }

  /// Fetches the native balance via `eth_getBalance`, preserving exact wei precision.
  private func fetchNativeBalance(chainId: Int) async throws -> RainCore.Balance {
    let walletAddress = try await fetchAddress()
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)
    let response = try await portal.request(
      chainId: chainIdString,
      method: .eth_getBalance,
      params: [walletAddress, "latest"],
      options: nil
    )
    let raw = try parseBalanceString(portalResultString(response))
    let native = await tokenStore.nativeCurrency(for: chainId)
    return RainCore.Balance(
      token: .native,
      chainId: chainId,
      rawAmount: raw,
      decimals: native.decimals,
      symbol: native.symbol,
      name: native.name
    )
  }

  /// Fetches a single ERC-20 balance via direct RPC `eth_call` (balanceOf), preserving exact precision.
  private func fetchContractBalance(chainId: Int, address: String) async throws -> RainCore.Balance {
    let walletAddress = try await fetchAddress()
    let info = await tokenStore.tokenInfo(chainId: chainId, address: address)
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)
    let callData = Multicall3.encodeBalanceOf(address: walletAddress)
    let callParams: [String: Any] = [
      "to": address,
      "data": callData
    ]

    do {
      let response = try await portal.request(
        chainId: chainIdString,
        method: .eth_call,
        params: [callParams, "latest"],
        options: nil
      )
      let raw = try EthereumConverter.parseHexToBigUIntStrict(response.hexString)
      return RainCore.Balance(
        token: .contract(address: address),
        chainId: chainId,
        rawAmount: raw,
        decimals: info.decimals,
        symbol: info.symbol,
        name: info.name
      )
    } catch {
      if error is RainError { throw error }
      // This path wraps Portal errors itself (so a read-path revert never classifies as a failed
      // simulation), which would otherwise also swallow an expired session — map auth first.
      if let authError = PortalErrorMapping.mapAuthOrNil(error) { throw authError }
      RainLogger.error("Rain SDK: Failed to get ERC20 balance via RPC for token=\(address) chainId=\(chainId): \(error)")
      throw RainError.providerError(underlying: error)
    }
  }

  /// Extracts the string payload from a Portal RPC result, whether wrapped in a
  /// `PortalProviderRpcResponse` or returned as a raw `String`.
  private func portalResultString(_ response: PortalProviderResult) -> String? {
    if let rpcResponse = response.result as? PortalProviderRpcResponse {
      return rpcResponse.result
    }
    if let stringResult = response.result as? String {
      return stringResult
    }
    return nil
  }

  /// Parses a balance string that may be hex (`0x…`, production) or decimal (mocks / some
  /// transports) into an exact `BigUInt`. Malformed hex throws instead of collapsing to a
  /// silent zero balance.
  private func parseBalanceString(_ value: String?) throws -> BigUInt {
    guard let value, !value.isEmpty else { return 0 }
    if value.hasPrefix("0x") || value.hasPrefix("0X") {
      return try EthereumConverter.parseHexToBigUIntStrict(value)
    }
    return BigUInt(value) ?? 0
  }

  /// Reconstructs the exact base-unit amount for a Portal asset entry: prefer the raw
  /// integer string when present, else reconstruct from the formatted decimal balance.
  private func reconstructRawAmount(entry: TokenBalanceResponse, decimals: Int) -> BigUInt {
    if let rawBalance = entry.rawBalance, let raw = BigUInt(rawBalance) {
      return raw
    }
    return EthereumConverter.decimalStringToBigUInt(entry.balance, decimals: decimals)
  }

  /// Auto-enriches missing `value` and `asset` fields on returned transactions via on-chain
  /// `decimals()` / `symbol()` calls — Portal's transaction API returns raw contract data
  /// but not the human-readable values, so we backfill them here.
  public func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)
    let portalOrder = order?.toPortalOrder
    let fetchedTransactions = try await sessions.executeRead {
      try await portal.getTransactions(
        chainIdString,
        limit: limit,
        offset: offset,
        order: portalOrder
      )
    }

    // Resolve metadata once per distinct contract, then build each row with everything known —
    // rows are immutable, so nothing is patched after construction.
    let tokenInfoByAddress = await resolveTokenInfo(for: fetchedTransactions, chainId: chainId)
    // Nil rather than an ETH-like default: labelling an unlisted chain's gas token "ETH" would be
    // wrong, and no symbol beats a wrong one.
    let nativeSymbol = await tokenStore.nativeCurrencyOrNil(for: chainId)?.symbol

    return fetchedTransactions.map { tx in
      RainTransaction.make(
        tx,
        tokenInfo: tx.rawContract?.address.flatMap { tokenInfoByAddress[$0] },
        nativeSymbol: nativeSymbol
      )
    }
  }

  // MARK: - Transaction Enrichment

  /// Reads `decimals()` / `symbol()` for every distinct contract in the page, concurrently.
  /// A row that already carries both a parsed value and an asset needs neither.
  private func resolveTokenInfo(
    for transactions: [FetchedTransaction],
    chainId: Int
  ) async -> [String: TokenInfo] {
    let addresses = Set(
      transactions.compactMap { tx -> String? in
        guard let address = tx.rawContract?.address, !address.isEmpty else { return nil }
        let needsDecimals = tx.value == nil && tx.rawContract?.value != nil && tx.rawContract?.decimal == nil
        let needsSymbol = tx.asset?.isEmpty ?? true
        return (needsDecimals || needsSymbol) ? address : nil
      }
    )
    guard !addresses.isEmpty else { return [:] }

    var resolved: [String: TokenInfo] = [:]
    await withTaskGroup(of: (String, TokenInfo).self) { group in
      for address in addresses {
        group.addTask { [tokenStore] in
          (address, await tokenStore.tokenInfo(chainId: chainId, address: address))
        }
      }
      for await (address, info) in group {
        resolved[address] = info
      }
    }
    return resolved
  }

  /// Fetches gas-related RPC result (e.g. eth_estimateGas, eth_gasPrice) via Portal; returns the
  /// exact wei-level value as `BigUInt`.
  ///
  /// The underlying `PortalProviderResult.result` can come back in different shapes depending on
  /// the Portal SDK / transport. This helper supports:
  /// - `PortalProviderRpcResponse` whose `result` is a hex (`0x…`) or decimal string
  /// - a raw hex or decimal `String`
  /// - a raw numeric type (`NSNumber`)
  private func fetchGasData(
    chainId: Int,
    method: PortalRequestMethod,
    address: String,
    params: [Any] = []
  ) async throws -> BigUInt {
    let chainIdString = ChainIDFormat.EIP155.format(chainId: chainId)

    let response = try await portal.request(
      chainId: chainIdString,
      method: method,
      params: params,
      options: nil
    )

    // 1) Preferred: PortalProviderRpcResponse wrapping a string result
    if let rpcResponse = response.result as? PortalProviderRpcResponse,
       let stringResult = rpcResponse.result,
       let value = Self.parseGasValue(stringResult) {
      return value
    }

    // 2) Fallback: raw string result
    if let stringResult = response.result as? String,
       let value = Self.parseGasValue(stringResult) {
      return value
    }

    // 3) Fallback: raw numeric result
    if let numberResult = response.result as? NSNumber,
       let value = BigUInt(numberResult.stringValue) {
      return value
    }

    RainLogger.error("Rain SDK: Error fetching \(method) for \(address). Unexpected RPC response")
    throw RainError.internalError(
      details: "Unexpected RPC response when fetching \(method) for \(address)"
    )
  }

  /// Parses a gas value string that may be hex (`0x…`, production) or decimal (mocks / some
  /// transports) into an exact `BigUInt`. Integral float renderings (`"21000.0"`) are accepted;
  /// fractional or otherwise malformed values return `nil`.
  private static func parseGasValue(_ value: String) -> BigUInt? {
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("0x") || value.hasPrefix("0X") {
      return BigUInt(value.dropFirst(2), radix: 16)
    }
    if let integral = BigUInt(value) {
      return integral
    }
    // Some transports render integral gas values as floats. Parse exactly via Decimal (no Double
    // rounding) and accept only a whole, non-negative value; the strict full-match pattern keeps
    // genuinely malformed input (trailing junk, negatives) rejected.
    let pattern = "^[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"
    guard value.range(of: pattern, options: .regularExpression) != nil,
          let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
      return nil
    }
    var source = decimal
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, 0, .down)
    guard rounded == decimal else { return nil }
    return BigUInt(NSDecimalNumber(decimal: rounded).stringValue, radix: 10)
  }
}

private enum UserOperationLookup {
  /// `UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)`, identical across
  /// EntryPoint versions. Topic 1 is the UserOperation hash.
  static let eventTopic = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"

  /// Canonical EntryPoint deployments, v0.6 through v0.8.
  static let entryPoints = [
    "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789",
    "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108"
  ]

  static let attempts = 20
  static let interval: Duration = .seconds(1)
}

private struct UserOperationReverted: LocalizedError {
  let hash: String
  let transactionHash: String

  var errorDescription: String? {
    "UserOperation \(hash) reverted on-chain in transaction \(transactionHash)"
  }
}
