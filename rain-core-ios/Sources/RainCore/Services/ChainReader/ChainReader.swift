import Foundation
import Web3

/// Provider-agnostic, read-only on-chain query surface.
///
/// One place for reading state from any chain the SDK consumer has configured. Used by
/// `TurnkeyWalletProviderAdapter` to fill in balances on chains outside the Turnkey
/// `get-balances` allowlist, and available to any future wallet provider adapter that
/// needs the same fallback.
///
/// V1 surface is balances. Future reads (token metadata, allowances, generic `eth_call`
/// wrappers) belong on this protocol so call sites don't fragment.
///
/// Implementations exist per chain family. `EVMChainReader` covers all EIP-155 chains
/// via JSON-RPC. A future Solana/Stellar reader can conform alongside it; until then,
/// `chainId: Int` matches the rest of the SDK's EVM-centric typing.
@_spi(RainAdapter) public protocol ChainReader: Sendable {
  /// Native balance (e.g. ETH on Ethereum, AVAX on Avalanche).
  /// - Returns: Balance in human-readable form (e.g. `1.5` for 1.5 ETH), as an exact `Decimal`.
  func getNativeBalance(chainId: Int, walletAddress: String) async throws -> Decimal

  /// Single ERC-20 balance via `balanceOf(address)`.
  /// - Parameter decimals: Token decimal places; defaults to `Constants.ERC20.defaultDecimals` if nil.
  func getERC20Balance(
    chainId: Int,
    tokenAddress: String,
    walletAddress: String,
    decimals: Int?
  ) async throws -> Decimal

  /// Batched balances for many tokens on one chain, in a single round-trip when possible.
  /// - Parameter tokens: ERC-20 tokens to query. The native balance is always included.
  /// - Returns: One `Balance` per successfully-read token plus the native balance
  ///   (`Token.native`). Tokens whose `balanceOf` reverts are omitted; zero balances are
  ///   retained (zero-filtering is the caller's responsibility).
  func getBalances(
    chainId: Int,
    walletAddress: String,
    tokens: [TokenInfo]
  ) async throws -> [Balance]

  /// Reads a single balance (native or a contract token) as a rich `Balance`.
  /// - Parameter tokenInfo: Pre-resolved metadata for a `.contract` token (decimals / symbol /
  ///   name); ignored for `.native`. When `nil` for a contract token, defaults are used.
  func getBalance(
    chainId: Int,
    walletAddress: String,
    token: Token,
    tokenInfo: TokenInfo?
  ) async throws -> Balance

  /// Reads an ERC-20 token's `decimals()`. Used to enrich tokens not in the registry.
  func getDecimals(chainId: Int, tokenAddress: String) async throws -> Int

  /// Reads an ERC-20 token's `symbol()`. Returns `nil` if the call reverts or returns
  /// an undecodable payload. Used to enrich tokens not in the registry.
  func getSymbol(chainId: Int, tokenAddress: String) async throws -> String?

  /// Reads an ERC-20 token's `name()`. Returns `nil` if the call reverts or returns
  /// an undecodable payload. Used to enrich tokens not in the registry.
  func getName(chainId: Int, tokenAddress: String) async throws -> String?

  /// Reads `allowance(owner, spender)` — the base units of `owner`'s token balance that
  /// `spender` may still move. Returned raw because an unlimited approval (uint256 max)
  /// overflows `Decimal`; scaling is the caller's decision.
  /// - Parameter atBlock: Block tag to read at; pass a ``MinedReceipt/blockNumber`` to read state
  ///   that provably includes that transaction.
  func getERC20Allowance(
    chainId: Int,
    tokenAddress: String,
    owner: String,
    spender: String,
    atBlock: String
  ) async throws -> BigUInt

  /// Reads a transaction's receipt.
  /// - Returns: `nil` while the transaction is still pending; otherwise its outcome and block.
  func getTransactionReceipt(
    chainId: Int,
    transactionHash: String
  ) async throws -> MinedReceipt?
}

extension ChainReader {
  /// Reads the allowance at the chain head, for callers with no transaction to pin to.
  func getERC20Allowance(
    chainId: Int,
    tokenAddress: String,
    owner: String,
    spender: String
  ) async throws -> BigUInt {
    try await getERC20Allowance(
      chainId: chainId,
      tokenAddress: tokenAddress,
      owner: owner,
      spender: spender,
      atBlock: BlockTag.latest
    )
  }
}

internal enum BlockTag {
  /// Whatever head the answering node is at — fine standalone, stale for verifying a transaction.
  static let latest = "latest"
}

/// A mined transaction's outcome and the block it landed in, so a read can be pinned to that block.
@_spi(RainAdapter) public struct MinedReceipt: Equatable, Sendable {
  /// `true` when the transaction mined successfully, `false` when it mined but reverted.
  let succeeded: Bool

  /// Hex quantity (e.g. `"0x10"`), carried verbatim so it can be reused as a block tag.
  let blockNumber: String
}
