import Foundation

/// Owns per-chain token reference data plus a runtime enrichment cache.
///
/// Seeded from `TokenRegistry` defaults and extendable at runtime via `register(_:)`
/// (host apps adding their own tokens). Unknown `.contract` tokens are enriched on demand
/// by reading `decimals()` / `symbol()` through a `ChainReader`, then cached so a given
/// token is only enriched once.
///
/// An `actor` because enrichment fans out async RPC across task groups; actor isolation
/// gives reentrant-safe access to the registry and cache without manual locking.
public actor TokenMetadataStore {
  private let chainReader: ChainReader

  /// Known tokens per chain: built-in registry plus host-registered. Insertion order is
  /// preserved (registry order first, then registrations) so balance reads are deterministic.
  private var knownTokens: [Int: [TokenInfo]]

  /// Tokens discovered and enriched at runtime, keyed by chain ID then lowercased address.
  private var enrichmentCache: [Int: [String: TokenInfo]] = [:]

  @_spi(RainAdapter) public init(chainReader: ChainReader, seedTokens: [TokenInfo] = []) {
    self.chainReader = chainReader
    self.knownTokens = TokenRegistry.tokensByChainId
    for token in seedTokens {
      Self.upsert(token, into: &self.knownTokens)
    }
  }

  /// Adds host-supplied tokens. A token replaces an earlier host registration with the same
  /// address (case-insensitive) on the same chain. Built-in registry tokens are never replaced.
  /// Registers host tokens. The whole list is validated first (address well-formed for its chain
  /// family, decimals in 0...77) so one bad entry registers nothing — throws `invalidConfig`.
  public func register(_ tokens: [TokenInfo]) throws {
    try TokenInfoValidation.requireValid(tokens)
    for token in tokens {
      Self.upsert(token, into: &knownTokens)
    }
  }

  /// Native currency for a chain (gas token metadata).
  public func nativeCurrency(for chainId: Int) -> NativeCurrency {
    TokenRegistry.nativeCurrency(for: chainId)
  }

  /// Native currency for a chain, or `nil` when the chain is not in the registry. Unlike
  /// ``nativeCurrency(for:)`` this never falls back to an ETH-like default, so callers that must
  /// not show a wrong symbol (e.g. transaction history) can tell "unknown chain" apart.
  public func nativeCurrencyOrNil(for chainId: Int) -> NativeCurrency? {
    TokenRegistry.nativeCurrencyByChainId[chainId]
  }

  /// All known tokens for a chain (registry + host-registered), in deterministic order.
  public func registeredTokens(for chainId: Int) -> [TokenInfo] {
    knownTokens[chainId] ?? []
  }

  /// Resolves metadata for a contract token: known tokens first, then the enrichment
  /// cache, then a one-time on-chain `decimals()` / `symbol()` / `name()` read (cached on
  /// success). A failed `decimals()` read falls back to the 18-decimal default (and is NOT
  /// cached, so the next lookup re-reads the chain) — display paths tolerate that; money paths
  /// must use ``resolvedTokenInfo(chainId:address:)`` / ``decimals(chainId:address:)`` instead.
  public func tokenInfo(chainId: Int, address: String) async -> TokenInfo {
    await resolve(chainId: chainId, address: address).info
  }

  /// Strict metadata resolution — the same walk as ``tokenInfo(chainId:address:)`` but `nil`
  /// when decimals could not be established, never the 18-decimal default. The answer a host
  /// needs before scaling a money amount for a token it only knows by address (e.g. the tokens
  /// in a Rain collateral contract).
  ///
  /// - Throws: `RainError.invalidConfig` when the chain reports `decimals()` outside 0...77 — a
  ///   token no money path can scale by. Nothing is cached then.
  public func resolvedTokenInfo(chainId: Int, address: String) async throws -> TokenInfo? {
    let resolved = await resolve(chainId: chainId, address: address)
    guard resolved.decimalsResolved else { return nil }
    try TokenInfoValidation.requireValidChainDecimals(
      resolved.info.decimals, chainId: chainId, address: address
    )
    return resolved.info
  }

  /// A contract token's decimals, or `nil` when they could not be established.
  ///
  /// Never substitutes the 18-decimal default. Callers that scale a *money amount* must use
  /// this: on an approval a guessed 18 against a 6-decimal token would silently approve 10^12
  /// times the intended allowance, and `approve` has no balance to fail against, so nothing
  /// downstream would catch it.
  public func decimals(chainId: Int, address: String) async throws -> Int? {
    try await resolvedTokenInfo(chainId: chainId, address: address)?.decimals
  }

  // MARK: - Resolution

  /// The single lookup walk every public accessor shares: known tokens (registry + registered),
  /// then the enrichment cache, then an on-chain read. Only a read whose `decimals()` resolved
  /// is cached — a fallback decimals is a guess, not a fact, and caching it would pin a value
  /// wrong by orders of magnitude for the rest of the process. Solana chains stop at the known
  /// tokens: the on-chain read path is EVM-only and an SPL mint carries no on-chain symbol.
  private func resolve(chainId: Int, address: String) async -> Enriched {
    let key = address.lowercased()
    if let known = knownTokens[chainId]?.first(where: { $0.address.lowercased() == key }) {
      return Enriched(info: known, decimalsResolved: true)
    }
    if let cached = enrichmentCache[chainId]?[key] {
      return Enriched(info: cached, decimalsResolved: true)
    }
    if SolanaChains.isSolana(chainId) {
      return Enriched(
        info: TokenInfo(
          chainId: chainId, address: address, symbol: nil,
          decimals: Constants.ERC20.defaultDecimals, name: nil
        ),
        decimalsResolved: false
      )
    }
    let enriched = await enrich(chainId: chainId, address: address)
    // Cache only a chain answer a money path can use; an out-of-range decimals is refused by the
    // strict accessors and must meet the same refusal on the next lookup.
    if enriched.decimalsResolved, TokenInfoValidation.decimalsRange.contains(enriched.info.decimals) {
      enrichmentCache[chainId, default: [:]][key] = enriched.info
    }
    return enriched
  }

  // MARK: - Enrichment

  /// An enrichment result plus whether `decimals` came from the chain or the fallback.
  private struct Enriched {
    let info: TokenInfo
    let decimalsResolved: Bool
  }

  /// Reads `decimals()`, `symbol()` and `name()` in parallel. A failed `decimals()` falls
  /// back to the default; a failed `symbol()` / `name()` leaves that field `nil`.
  private func enrich(chainId: Int, address: String) async -> Enriched {
    async let decimalsTask = chainReader.getDecimals(chainId: chainId, tokenAddress: address)
    async let symbolTask = chainReader.getSymbol(chainId: chainId, tokenAddress: address)
    async let nameTask = chainReader.getName(chainId: chainId, tokenAddress: address)

    let resolvedDecimals = try? await decimalsTask
    let symbol = (try? await symbolTask) ?? nil
    let name = (try? await nameTask) ?? nil

    if resolvedDecimals == nil {
      // Falling back here misreports the balance by orders of magnitude for any
      // non-18-decimal token, so it must never fail silently.
      RainLogger.warning(
        "Rain SDK: decimals() read failed for token=\(address) chainId=\(chainId) — "
          + "falling back to \(Constants.ERC20.defaultDecimals)"
      )
    }

    return Enriched(
      info: TokenInfo(
        chainId: chainId,
        address: address,
        symbol: symbol,
        decimals: resolvedDecimals ?? Constants.ERC20.defaultDecimals,
        name: name
      ),
      decimalsResolved: resolvedDecimals != nil
    )
  }

  // MARK: - Helpers

  private static func upsert(_ token: TokenInfo, into store: inout [Int: [TokenInfo]]) {
    let key = token.address.lowercased()
    // The registry is the trusted source for its own tokens: a host-supplied `decimals` for one
    // would rescale every balance and approval against it, so the registration is dropped.
    if let trusted = TokenRegistry.tokens(for: token.chainId).first(where: { $0.address.lowercased() == key }) {
      if trusted != token {
        RainLogger.warning(
          "Rain SDK: Ignoring registration of \(token.address) on chain \(token.chainId): "
            + "built-in token \(trusted.symbol ?? "?") (\(trusted.decimals) decimals) cannot be overridden"
        )
      }
      return
    }
    var list = store[token.chainId] ?? []
    if let index = list.firstIndex(where: { $0.address.lowercased() == key }) {
      list[index] = token
    } else {
      list.append(token)
    }
    store[token.chainId] = list
  }
}
