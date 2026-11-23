import Foundation
import CoreGraphics
import Web3

/// The wallet-bound client surface resolved from `RainSdk.provider(_:)` / `RainSdk.first { }`.
///
/// Every method here operates against the single wallet provider this client was resolved for.
/// Wallet-agnostic building (EIP-712 message, withdraw calldata, transaction parameters) lives on
/// ``RainSdk`` instead, since it needs no resolved provider.
public protocol RainClient: Sendable {
  // MARK: - Client metadata

  /// Identifier of the provider backing this client (e.g. ``ProviderId/portal``).
  var providerId: ProviderId { get }

  /// Optional behaviours the backing provider supports (see ``Capability``).
  var capabilities: Set<Capability> { get }

  /// Whether the SDK's chain configuration is set up. A `RainClient` only exists once its
  /// provider has resolved against a validated configuration, so this is always `true` for a
  /// live client.
  var isInitialized: Bool { get }

  /// Clears client-held state. A resolved client is immutable (configuration and the backing
  /// provider are fixed at resolution), so there is nothing to tear down at this level; the
  /// method is idempotent. Prefer ``RainSdk/reset()``, which evicts resolved clients so they
  /// re-resolve on next access.
  func reset()

  // MARK: - Collateral / fees

  /// Executes a collateral withdrawal on-chain and returns the transaction hash (EVM) or
  /// transaction signature (Solana). `decimals` scales `amount` on every chain including Solana,
  /// where it is not checked against the SPL mint — pass the mint's real decimals.
  func withdrawCollateral(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> String

  /// Builds a collateral withdrawal without broadcasting it. See ``RainPreparedWithdrawal`` for
  /// what this does and does not do offline, and for the Solana blockhash lifetime.
  func prepareWithdrawal(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> RainPreparedWithdrawal

  /// Estimates the total fee (estimated gas × gas price) to execute an arbitrary transaction,
  /// in the chain's native token (e.g. ETH, AVAX).
  ///
  /// - Parameters:
  ///   - chainId: Target network chain ID.
  ///   - from: Sender wallet address.
  ///   - to: Target contract address.
  ///   - data: Hex-encoded transaction calldata.
  func estimateGas(
    chainId: Int,
    from: String,
    to: String,
    data: String
  ) async throws -> Decimal

  /// Estimates the total fee (gas cost) to execute a collateral withdrawal, in the chain's
  /// native token. EVM only — throws on a Solana chain id.
  ///
  /// Builds — and therefore **signs** — a complete withdrawal to estimate against, so the wallet
  /// produces a real EIP-712 signature (a user-visible prompt on providers that gate signing) even
  /// though nothing broadcasts.
  /// To quote a fee without a second prompt, call ``prepareWithdrawal(chainId:addresses:amount:decimals:adminSignature:nonce:)``
  /// once and estimate on the result with ``estimateWithdrawalFee(chainId:prepared:)``.
  func estimateWithdrawalFee(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> Decimal

  /// Estimates the total fee (gas cost) for an already-prepared withdrawal, in the chain's native
  /// token, without building or signing anything new — no wallet prompt. EVM only — throws on a
  /// Solana preparation.
  func estimateWithdrawalFee(
    chainId: Int,
    prepared: RainPreparedWithdrawal
  ) async throws -> Decimal

  // MARK: - Wallet information

  /// Returns the current wallet address (EVM EOA, 0x…).
  func getWalletAddress() async throws -> String

  /// Returns the wallet address for a specific chain's family (Solana account for Solana
  /// sentinel chains, EVM address otherwise).
  func getWalletAddress(chainId: Int) async throws -> String

  /// Generates a square QR code (PNG) encoding `address`, or the wallet's own address when
  /// `address` is `nil`.
  ///
  /// Use this for any address the host needs to show — a chain-specific wallet address (the
  /// Solana account rather than the EVM one), or a Rain collateral deposit address.
  ///
  /// - Parameters:
  ///   - address: Address to encode. `nil` encodes the provider's wallet address.
  ///   - dimension: Output width and height in pixels (the QR is square).
  ///   - backgroundColor: Background colour; `nil` uses white.
  ///   - foregroundColor: QR module colour; `nil` uses black.
  func generateAddressQRCode(
    address: String?,
    dimension: Int,
    backgroundColor: CGColor?,
    foregroundColor: CGColor?
  ) async throws -> Data

  // MARK: - Fetch balances

  /// Fetches a single balance (native or a contract token) for the current wallet.
  func getBalance(chainId: Int, token: Token) async throws -> Balance

  /// Fetches all non-zero balances (native always included) for the current wallet on a network.
  func getTokenBalances(chainId: Int) async throws -> [Balance]

  /// Fetches balances across every configured chain in parallel, flattened into one list.
  func getAllBalances() async throws -> [Balance]

  // MARK: - Transactions

  /// Fetches transaction history for the current wallet on the given network.
  func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction]

  // MARK: - Send tokens

  /// Sends native tokens (e.g. ETH, AVAX) on the specified network.
  func sendNative(
    chainId: Int,
    to: String,
    amount: Decimal
  ) async throws -> RainTokenTransferResult

  /// Sends ERC-20 (EVM) or SPL (Solana) tokens depending on `chainId`. Pass `nil` decimals to let
  /// the SDK resolve them from its registry or an on-chain read. On Solana `decimals` never scales
  /// the amount: the mint's own value is read from the chain and enforced by `TransferChecked`.
  func sendToken(
    chainId: Int,
    contractAddress: String,
    to: String,
    amount: Decimal,
    decimals: Int?
  ) async throws -> RainTokenTransferResult

  // MARK: - Token approvals (Auth Pull)

  /// The chains this client will accept an Auth Pull approval on, and the only answer that matches
  /// what the approval methods below enforce.
  ///
  /// Empty until `RainSdk.Builder.authPullConfig(_:)` supplies the trusted targets, and narrower
  /// than ``RainAuthPullChains/supported(for:)`` whenever the configuration is narrower than its
  /// environment or a chain has no RPC endpoint. Gate host UI on this rather than on the
  /// environment's chain set, so a chain is never offered that an approval would reject.
  var authPullChainIds: Set<Int> { get }

  /// Approves `spender` to move up to `amount` of an ERC-20 token from this wallet, and returns
  /// the resulting transaction hash.
  ///
  /// This is the wallet-side prerequisite for Rain's Auth Pull: the user's collateral contract
  /// must be approved on the user's wallet before an authorization can pull USDC into it. Rain
  /// executes the pull itself; the SDK only sets the allowance.
  ///
  /// Auth Pull is disabled until `RainSdk.Builder.authPullConfig(_:)` supplies the trusted token
  /// targets. This method rejects any different chain or token. The `approveTokenAllowance`
  /// section in docs/METHODS.md has the rules.
  ///
  /// - Parameters:
  ///   - chainId: EVM chain the token lives on. Solana chain IDs throw — SPL has no
  ///     ERC-20-style allowance.
  ///   - contractAddress: The ERC-20 token contract (USDC for Auth Pull today).
  ///   - spender: The user's collateral contract on `chainId`, the `proxyAddress` the Rain API
  ///     returns. Take it from the Rain API, never from user input: the SDK's `isAdmin` read on it
  ///     stops a typo, a plain address and a contract of another kind, and does not prove that
  ///     Rain issued the contract.
  ///   - amount: Human-readable allowance (e.g. `250` for 250 USDC). `nil` approves an
  ///     unlimited (`uint256` max) allowance, so the user never has to re-approve; `0` revokes
  ///     an existing approval.
  /// - Throws: `invalidConfig` (RAIN_102), `walletNotAuthorized` (RAIN_407), `networkError`
  ///   (RAIN_301) or `internalError` (RAIN_502); the `approveTokenAllowance` section in
  ///   docs/METHODS.md has the condition for each.
  func approveTokenAllowance(
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?
  ) async throws -> RainTokenApprovalResult

  /// Reads the ERC-20 allowance `spender` currently holds over `owner`'s balance.
  ///
  /// Call it before approving (to skip a redundant transaction) and after (to confirm the
  /// approval was mined).
  ///
  /// - Parameters:
  ///   - owner: The wallet whose balance is approved. `nil` reads this client's own wallet, which
  ///     is the only case that touches the wallet provider at all.
  func getTokenAllowance(
    chainId: Int,
    contractAddress: String,
    spender: String,
    owner: String?
  ) async throws -> RainTokenAllowance

  /// Estimates the total fee (estimated gas × gas price) to submit the approval, in the chain's
  /// native token. Same parameters as
  /// ``approveTokenAllowance(chainId:contractAddress:spender:amount:)``; nothing is broadcast and
  /// no signature is requested. Throws as the approval does, the admin check included.
  func estimateApprovalFee(
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?
  ) async throws -> Decimal

  /// Waits for an approval transaction to mine successfully, then reads back the resulting
  /// allowance. A submitted transaction hash alone does not make Auth Pull ready.
  ///
  /// The returned allowance can legitimately be **lower** than `amount`: USDC decrements the
  /// allowance on every `transferFrom`, so an authorization that pulls between the receipt and
  /// this read leaves less than was approved. Compare ``RainTokenAllowance/rawAmount`` (or
  /// ``RainTokenAllowance/covers(_:)``) against what you need rather than against what you asked
  /// for. A revoke that left a spendable allowance, and an approval that mined against a
  /// still-zero allowance, both throw.
  ///
  /// - Parameters:
  ///   - transactionHash: The hash returned by `approveTokenAllowance`.
  ///   - amount: The allowance that was requested, so the result can be checked against it. `nil`
  ///     means the unlimited approval.
  ///   - owner: The wallet whose allowance to read. `nil` reads this client's own wallet.
  /// - Throws: `RainError.transactionSimulationFailed` when the mined transaction reverted,
  ///   `.transactionPending(statusId:)` (carrying the hash) when the confirmation window lapses
  ///   without a receipt — not a failure; resume polling rather than re-approving — and
  ///   `.internalError` when the mined allowance contradicts the request.
  func confirmTokenAllowance(
    transactionHash: String,
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?,
    owner: String?
  ) async throws -> RainTokenAllowance

  // MARK: - Token metadata

  /// Registers token metadata so balance and transfer calls can resolve symbol/decimals without an
  /// on-chain read. Entries are stored before this returns. Additive: re-registering a host-added
  /// address replaces its entry; built-in registry tokens are trusted and cannot be overridden.
  ///
  /// - Throws: `RainError.invalidConfig` when any entry has a malformed address for its chain
  ///   family or decimals outside 0...77 — the whole list is checked first, so nothing is stored.
  func registerTokens(_ tokens: [TokenInfo]) async throws
}

public extension RainClient {
  /// Withdraws collateral, letting the SDK read the collateral's current nonce on chain.
  func withdrawCollateral(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature
  ) async throws -> String {
    try await withdrawCollateral(
      chainId: chainId,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      adminSignature: adminSignature,
      nonce: nil
    )
  }

  /// Prepares a withdrawal, letting the SDK read the collateral's current nonce on chain.
  func prepareWithdrawal(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature
  ) async throws -> RainPreparedWithdrawal {
    try await prepareWithdrawal(
      chainId: chainId,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      adminSignature: adminSignature,
      nonce: nil
    )
  }

  /// Estimates the withdrawal fee, letting the SDK read the collateral's current nonce on chain.
  func estimateWithdrawalFee(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature
  ) async throws -> Decimal {
    try await estimateWithdrawalFee(
      chainId: chainId,
      addresses: addresses,
      amount: amount,
      decimals: decimals,
      adminSignature: adminSignature,
      nonce: nil
    )
  }

  /// Generates a 256 px QR code (PNG) with the default colours, encoding `address` — or the
  /// wallet's own address when `address` is omitted.
  func generateAddressQRCode(address: String? = nil) async throws -> Data {
    try await generateAddressQRCode(
      address: address,
      dimension: 256,
      backgroundColor: nil,
      foregroundColor: nil
    )
  }

  /// Sends tokens letting the SDK resolve the token's `decimals()` itself.
  func sendToken(
    chainId: Int,
    contractAddress: String,
    to: String,
    amount: Decimal
  ) async throws -> RainTokenTransferResult {
    try await sendToken(
      chainId: chainId,
      contractAddress: contractAddress,
      to: to,
      amount: amount,
      decimals: nil
    )
  }

  /// Auth Pull disabled, for a conformer that predates the trusted configuration. Defaulted rather
  /// than required so adding this did not break existing conformers, and `[]` is the safe answer:
  /// it advertises no chain the approval guard has not been told to accept.
  var authPullChainIds: Set<Int> { [] }

  /// Approves an **unlimited** allowance for `spender`, so the user never has to re-approve.
  /// This is what Rain recommends for Auth Pull. Pass an explicit `amount` to cap it, or `0` to
  /// revoke.
  ///
  /// Reduced-arity on purpose: a full-signature extension member would be a self-calling default
  /// witness.
  func approveTokenAllowance(
    chainId: Int,
    contractAddress: String,
    spender: String
  ) async throws -> RainTokenApprovalResult {
    try await approveTokenAllowance(
      chainId: chainId,
      contractAddress: contractAddress,
      spender: spender,
      amount: nil
    )
  }

  /// Reads the allowance `spender` holds over this client's own wallet.
  func getTokenAllowance(
    chainId: Int,
    contractAddress: String,
    spender: String
  ) async throws -> RainTokenAllowance {
    try await getTokenAllowance(
      chainId: chainId,
      contractAddress: contractAddress,
      spender: spender,
      owner: nil
    )
  }

  /// Estimates the fee for an unlimited approval.
  func estimateApprovalFee(
    chainId: Int,
    contractAddress: String,
    spender: String
  ) async throws -> Decimal {
    try await estimateApprovalFee(
      chainId: chainId,
      contractAddress: contractAddress,
      spender: spender,
      amount: nil
    )
  }

  /// Confirms an approval against this client's own wallet.
  func confirmTokenAllowance(
    transactionHash: String,
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?
  ) async throws -> RainTokenAllowance {
    try await confirmTokenAllowance(
      transactionHash: transactionHash,
      chainId: chainId,
      contractAddress: contractAddress,
      spender: spender,
      amount: amount,
      owner: nil
    )
  }

  /// Confirms an unlimited approval against this client's own wallet.
  func confirmTokenAllowance(
    transactionHash: String,
    chainId: Int,
    contractAddress: String,
    spender: String
  ) async throws -> RainTokenAllowance {
    try await confirmTokenAllowance(
      transactionHash: transactionHash,
      chainId: chainId,
      contractAddress: contractAddress,
      spender: spender,
      amount: nil,
      owner: nil
    )
  }

  /// Fetches transaction history with the provider's defaults. Reduced-arity on purpose: a
  /// full-signature extension member would be a self-calling default witness.
  func getTransactions(chainId: Int) async throws -> [RainTransaction] {
    try await getTransactions(
      chainId: chainId,
      limit: nil,
      offset: nil,
      order: nil
    )
  }
}
