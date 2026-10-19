import Foundation
import CoreGraphics
import Web3

/// Concrete ``RainClient`` bound to a single resolved wallet provider. Constructed by
/// ``RainSdk`` when a provider is resolved; not created directly by hosts.
///
/// Holds the shared vendor-free services (transaction builder, token store) plus the one
/// `WalletProvider` this client speaks to. All wallet operations delegate to that provider.
final class RainSdkManager: RainClient, @unchecked Sendable {
  let walletProvider: any WalletProvider
  private let networkConfigs: [NetworkConfig]
  let transactionBuilderService: TransactionBuilderProtocol
  let tokenStore: TokenMetadataStore

  /// Read-only chain access for state the wallet provider does not expose — today, ERC-20
  /// allowances. Balances still route through the provider, which may have a faster native API.
  let chainReader: ChainReader

  let providerId: ProviderId
  let capabilities: Set<Capability>

  /// Composes Solana collateral withdrawals. Built from `networkConfigs` so it resolves the same
  /// cluster endpoints every other Solana read uses.
  let solanaWithdrawComposer: SolanaCollateralWithdrawComposer

  /// Chains an Auth Pull approval may target: the host's ``RainAuthPullConfig`` narrowed to the
  /// chains that have an RPC endpoint. Held as a resolved set rather than the environment itself so
  /// the approval guard has one thing to check and no opinion about API hosts, and surfaced on
  /// ``RainClient`` so host UI can gate on exactly what the guard enforces.
  let authPullChainIds: Set<Int>

  /// Rain's operator for the configured environment: the only spender an approval may name.
  let authPullOperator: String?

  /// The trusted token contract per Auth Pull chain: the only token an approval may target.
  let authPullTokenAddresses: [Int: String]

  /// Delay between `confirmTokenAllowance` polls. Injectable so tests can drive the whole window.
  let approvalConfirmationInterval: Duration

  init(
    walletProvider: any WalletProvider,
    networkConfigs: [NetworkConfig],
    transactionBuilder: TransactionBuilderProtocol,
    tokenStore: TokenMetadataStore,
    providerId: ProviderId,
    capabilities: Set<Capability>,
    chainReader: ChainReader? = nil,
    authPullChainIds: Set<Int> = [],
    authPullOperator: String? = nil,
    authPullTokenAddresses: [Int: String] = [:],
    approvalConfirmationInterval: Duration = ApprovalConfirmation.interval
  ) {
    self.authPullChainIds = authPullChainIds
    self.authPullOperator = authPullOperator
    self.authPullTokenAddresses = authPullTokenAddresses
    self.approvalConfirmationInterval = approvalConfirmationInterval
    self.walletProvider = walletProvider
    self.networkConfigs = networkConfigs
    self.transactionBuilderService = transactionBuilder
    self.tokenStore = tokenStore
    self.chainReader = chainReader ?? EVMChainReader(networkConfigs: networkConfigs)
    self.providerId = providerId
    self.capabilities = capabilities
    self.solanaWithdrawComposer = SolanaCollateralWithdrawComposer(
      rpcClient: SolanaRpcClient(networkConfigs: networkConfigs)
    )
  }

  // MARK: - Client metadata

  /// A `RainSdkManager` only exists once its provider resolved against a validated
  /// configuration, so this is constant `true`.
  var isInitialized: Bool { true }

  /// No-op: a resolved client is immutable on iOS (see the ``RainClient/reset()`` doc comment).
  /// `RainSdk.reset()` is the operation that actually evicts resolved clients.
  func reset() {
    RainLogger.info("Rain SDK: RainClient.reset() called; resolved clients are immutable on iOS, use RainSdk.reset() to evict them")
  }

  /// Registers token metadata into the store shared with the owning `RainSdk`, so every resolved
  /// client sees it. Fire-and-forget, to keep registration synchronous for callers.
  func registerTokens(_ tokens: [TokenInfo]) async throws {
    try await tokenStore.register(tokens)
  }

  // MARK: - Collateral / fees

  func withdrawCollateral(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> String {
    do {
      // Before the contract reads and the signing prompt: a chain the provider cannot broadcast
      // on fails closed here, not after the user has authorised a withdrawal that cannot go out.
      try walletProvider.requireSendSupport(chainId: chainId)
      let prepared = try await buildPreparedWithdrawal(
        chainId: chainId,
        assetAddresses: addresses,
        amount: amount,
        decimals: decimals,
        adminSignature: adminSignature,
        nonce: nonce
      )

      switch prepared {
      case let .solana(unsigned):
        guard let solanaProvider = walletProvider as? any RainSolanaTransfersProvider else {
          throw RainError.internalError(
            details: "The active wallet provider does not support Solana transfers"
          )
        }
        let signature = try await solanaProvider.signAndSendSolanaTransaction(
          chainId: chainId,
          unsigned: unsigned
        )
        RainLogger.info("Rain SDK: Solana withdrawal submitted. Signature: \(signature)")
        return signature

      case let .evm(parameters):
        let txHash = try await walletProvider.sendTransaction(
          chainId: chainId,
          params: walletParams(parameters)
        )
        RainLogger.info("Rain SDK: Withdrawal transaction submitted. Hash: \(txHash)")
        return txHash
      }
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw mapWithdrawalError(error)
    }
  }

  func prepareWithdrawal(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> RainPreparedWithdrawal {
    do {
      // Deliberately NOT gated on `requireSendSupport`: preparing only signs the EIP-712 message
      // (or composes the Solana transaction) and never broadcasts, and signing is not limited to
      // the provider's broadcast chains. The prepared parameters are also what a host can submit
      // through its own RPC on a chain the provider cannot broadcast on.
      return try await buildPreparedWithdrawal(
        chainId: chainId,
        assetAddresses: addresses,
        amount: amount,
        decimals: decimals,
        adminSignature: adminSignature,
        nonce: nonce
      )
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw mapWithdrawalError(error)
    }
  }

  func estimateGas(
    chainId: Int,
    from: String,
    to: String,
    data: String
  ) async throws -> Decimal {
    do {
      let params = WalletTransactionParams(
        from: from,
        to: to,
        value: 0.ethToWei.toHexString,
        data: data
      )
      return try await estimateTransactionFee(chainId: chainId, address: from, params: params)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func estimateWithdrawalFee(
    chainId: Int,
    addresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> Decimal {
    do {
      try validateWithdrawRequest(chainId: chainId, amount: amount, decimals: decimals)

      // TODO(v2.1): a Solana estimate is the flat per-signature fee plus token-account rent when
      // `UnsignedSolanaTransfer.createsRecipientAccount` is true.
      guard !SolanaChains.isSolana(chainId) else {
        throw RainError.internalError(
          details: "Withdrawal fee estimation is not supported on Solana"
        )
      }
      let (walletAddress, parameters) = try await prepareEvmWithdrawal(
        chainId: chainId,
        assetAddresses: addresses,
        amount: amount,
        decimals: decimals,
        adminSignature: adminSignature,
        nonce: nonce
      )
      return try await estimateTransactionFee(
        chainId: chainId,
        address: walletAddress,
        params: walletParams(parameters)
      )
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw mapWithdrawalError(error)
    }
  }

  func estimateWithdrawalFee(
    chainId: Int,
    prepared: RainPreparedWithdrawal
  ) async throws -> Decimal {
    do {
      guard let parameters = prepared.evmParameters else {
        throw RainError.internalError(
          details: "Withdrawal fee estimation is not supported on Solana"
        )
      }
      return try await estimateTransactionFee(
        chainId: chainId,
        address: parameters.from,
        params: walletParams(parameters)
      )
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw mapWithdrawalError(error)
    }
  }

  // MARK: - Wallet information

  func getWalletAddress() async throws -> String {
    do {
      return try await walletProvider.address()
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func getWalletAddress(chainId: Int) async throws -> String {
    do {
      return try await walletProvider.getAddress(chainId: chainId)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func generateAddressQRCode(
    address: String?,
    dimension: Int,
    backgroundColor: CGColor?,
    foregroundColor: CGColor?
  ) async throws -> Data {
    let target = if let address { address } else { try await getWalletAddress() }
    return try QRCodeRenderer.png(
      text: target,
      dimension: dimension,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor
    )
  }

  // MARK: - Fetch balances

  func getBalance(chainId: Int, token: Token) async throws -> Balance {
    do {
      return try await walletProvider.getBalance(chainId: chainId, token: token)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func getTokenBalances(chainId: Int) async throws -> [Balance] {
    do {
      return try await walletProvider.getBalances(chainId: chainId)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func getAllBalances() async throws -> [Balance] {
    let chainIds = networkConfigs.map(\.chainId)
    let provider = walletProvider
    // A chain that fails contributes no entries rather than failing the whole call, so one
    // bad RPC endpoint doesn't hide the others. A dead wallet session is the exception: it
    // affects every chain identically, and swallowing it would return an empty list a host
    // could mistake for zero balances.
    return try await withThrowingTaskGroup(of: [Balance].self) { group in
      for chainId in chainIds {
        group.addTask {
          do {
            return try await provider.getBalances(chainId: chainId)
          } catch let cancellation as CancellationError {
            throw cancellation
          } catch let error as RainError where error == .tokenExpired {
            throw error
          } catch {
            return []
          }
        }
      }
      var output: [Balance] = []
      for try await balances in group {
        output.append(contentsOf: balances)
      }
      return output
    }
  }

  // MARK: - Transactions

  func getTransactions(
    chainId: Int,
    limit: Int? = nil,
    offset: Int? = nil,
    order: RainTransactionOrder? = nil
  ) async throws -> [RainTransaction] {
    do {
      return try await walletProvider.getTransactions(
        chainId: chainId,
        limit: limit,
        offset: offset,
        order: order
      )
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  // MARK: - Send tokens

  func sendNative(
    chainId: Int,
    to: String,
    amount: Decimal
  ) async throws -> RainTokenTransferResult {
    do {
      if SolanaChains.isSolana(chainId) {
        guard let solanaProvider = walletProvider as? any RainSolanaTransfersProvider else {
          throw RainError.internalError(
            details: "The active wallet provider does not support Solana transfers"
          )
        }
        let signature = try await solanaProvider.sendSolanaNative(chainId: chainId, to: to, amount: amount)
        return RainTokenTransferResult(transactionHash: signature)
      }

      // A typo'd recipient would otherwise broadcast as-is and the funds are gone; validate and
      // checksum up front, as the withdrawal path does.
      guard let recipient = try? RainWithdrawAddresses.checksummed(to, label: "to") else {
        throw RainError.invalidRecipient(address: to, reason: "not a valid EVM address")
      }
      let from = try await walletProvider.address()
      let decimals = await tokenStore.nativeCurrency(for: chainId).decimals
      let amountWei = try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
      let params = WalletTransactionParams(
        from: from,
        to: recipient,
        value: "0x" + String(amountWei, radix: 16),
        data: .empty
      )

      let hash = try await walletProvider.sendTransaction(chainId: chainId, params: params)
      return RainTokenTransferResult(transactionHash: hash)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func sendToken(
    chainId: Int,
    contractAddress: String,
    to: String,
    amount: Decimal,
    decimals: Int?
  ) async throws -> RainTokenTransferResult {
    do {
      if SolanaChains.isSolana(chainId) {
        guard let solanaProvider = walletProvider as? any RainSolanaTransfersProvider else {
          throw RainError.internalError(
            details: "The active wallet provider does not support Solana transfers"
          )
        }
        // No `resolveDecimals` here: `tokenStore` enrichment reads `decimals()` through the EVM
        // reader, which cannot see a Solana mint and would cache a bogus 18. The adapter reads
        // the mint's own decimals and treats them as authoritative.
        let signature = try await solanaProvider.sendSolanaSPLToken(
          chainId: chainId,
          mintAddress: contractAddress,
          to: to,
          amount: amount,
          decimals: decimals ?? 0
        )
        return RainTokenTransferResult(transactionHash: signature)
      }

      // Validated here for a precise error — the ABI encoder would reject a malformed address
      // anyway, but only as an opaque "Failed to encode ERC-20".
      guard let recipient = try? RainWithdrawAddresses.checksummed(to, label: "to") else {
        throw RainError.invalidRecipient(address: to, reason: "not a valid EVM address")
      }
      let from = try await walletProvider.address()
      let resolvedDecimals = await resolveDecimals(
        chainId: chainId, contractAddress: contractAddress, decimals: decimals
      )
      let amountBaseUnits = try AmountHelpers.toBaseUnits(amount: amount, decimals: resolvedDecimals)
      let data = try await transactionBuilderService.buildERC20TransferData(
        chainId: chainId,
        contractAddress: contractAddress,
        walletAddress: from,
        toAddress: recipient,
        amount: amountBaseUnits
      )

      let params = WalletTransactionParams(
        from: from,
        to: contractAddress,
        value: 0.ethToWei.toHexString,
        data: data
      )

      let hash = try await walletProvider.sendTransaction(chainId: chainId, params: params)
      return RainTokenTransferResult(transactionHash: hash)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  // MARK: - Internal helpers

  /// Resolves a token's decimals: caller value if supplied, else the token store (registry, then
  /// a one-time on-chain read), falling back to the default.
  private func resolveDecimals(chainId: Int, contractAddress: String, decimals: Int?) async -> Int {
    if let decimals { return decimals }
    return await tokenStore.tokenInfo(chainId: chainId, address: contractAddress).decimals
  }
}
