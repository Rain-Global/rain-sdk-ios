import Foundation

/// Abstraction for a wallet/signer used for address, balance, transfers, and signing.
/// The port of the ports-and-adapters design: `TurnkeyWalletProviderAdapter`,
/// `PortalWalletProviderAdapter`, Privy's adapter, or a host's own implementation.
public protocol WalletProvider: Sendable {
  /// Returns the wallet address for the given chain.
  func address(
  ) async throws -> String

  /// Chain-aware wallet address. Defaults to `address()`; providers that manage more than one
  /// address family (e.g. Turnkey resolving a Solana account for Solana chains) override it.
  func getAddress(chainId: Int) async throws -> String

  /// Refuses a send on `chainId` before any work starts. Core calls this at the top of every
  /// flow that broadcasts (`withdrawCollateral`, Auth Pull approvals), so a chain the provider
  /// cannot broadcast on fails closed before the contract reads and the signing prompt rather
  /// than after them. Flows that only sign or build (`prepareWithdrawal`, estimates) are not
  /// gated — signing works on every chain, and the prepared transaction is a host's way to
  /// submit through its own RPC where the provider cannot broadcast. A provider that can broadcast on every configured chain keeps the no-op
  /// default; an adapter whose vendor broadcasts on a fixed set consults its own chain registry.
  ///
  /// - Throws: `RainError.chainNotSupported` when this provider cannot broadcast on `chainId`.
  func requireSendSupport(chainId: Int) throws

  /// True when this provider pays the network fee for sends on `chainId`, so core skips the
  /// self-paid preflights that would charge the fee to the wallet (the Solana fee-lamport check
  /// and dry run). Fee estimates are NOT affected: they still quote the on-chain cost, so a host
  /// can show what sponsorship saves. The per-chain refinement of `Capability.gasSponsorship`:
  /// a provider may sponsor only where it can broadcast. Defaults to false.
  func sponsorsFees(chainId: Int) -> Bool

  /// True when the provider's organization also funds the rent of a token account a Solana send
  /// on `chainId` creates, so core does not demand that rent from the sender before composing.
  /// Only consulted when `sponsorsFees(chainId:)` is true: the sponsor pre-funds rent inside a
  /// sponsored send only, so core combines the two. Defaults to false.
  func sponsorsRent(chainId: Int) -> Bool

  /// Sends a transaction; returns the transaction hash.
  func sendTransaction(
    chainId: Int,
    params: WalletTransactionParams
  ) async throws -> String

  /// Fetches a single balance (native or a contract token) as a rich `Balance`.
  /// - Parameters:
  ///   - chainId: The target blockchain network identifier.
  ///   - token: `.native` or a `.contract(address:)`.
  /// - Returns: A `Balance` with exact `rawAmount` plus resolved decimals / symbol / name.
  /// - Throws: RainError if wallet is unavailable or the request fails.
  func getBalance(
    chainId: Int,
    token: Token
  ) async throws -> Balance

  /// Fetches all non-zero balances for the current wallet on the given network.
  /// - Parameter chainId: The target blockchain network identifier.
  /// - Returns: One `Balance` per non-zero token plus the native balance (always included).
  /// - Throws: RainError if wallet is unavailable or the request fails.
  func getBalances(
    chainId: Int
  ) async throws -> [Balance]

  /// Fetches transaction history for the current wallet on the given network.
  /// - Parameters:
  ///   - chainId: The target blockchain network identifier.
  ///   - limit: Optional maximum number of transactions to return.
  ///   - offset: Optional offset for pagination.
  ///   - order: Optional sort order (e.g. newest first).
  /// - Returns: List of high-level `RainTransaction` records.
  /// - Throws: RainError if wallet is unavailable or the request fails.
  func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction]
}

public extension WalletProvider {
  /// EVM-only providers inherit the single-address behaviour.
  func getAddress(chainId: Int) async throws -> String {
    try await address()
  }

  /// Every configured chain is sendable unless the provider says otherwise.
  func requireSendSupport(chainId: Int) throws {}

  /// The wallet pays its own fees unless the provider says otherwise.
  func sponsorsFees(chainId: Int) -> Bool { false }

  /// The sender pays a created token account's rent unless the provider says otherwise.
  func sponsorsRent(chainId: Int) -> Bool { false }
}

