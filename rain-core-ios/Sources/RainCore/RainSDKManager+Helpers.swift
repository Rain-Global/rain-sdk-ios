import Foundation
import Web3

// MARK: Internal helpers for RainSdkManager (RainClient)
extension RainSdkManager {
  /// Maps an error thrown on a withdrawal flow (`withdrawCollateral` / `estimateWithdrawalFee`).
  /// A simulation revert on this path means the network rejected the withdrawal itself (e.g. a
  /// duplicate withdrawal or an already-used signature), so it surfaces as
  /// `.withdrawalRevertedByNetwork` (RAIN_405) here and only here; plain sends and reads keep
  /// `.transactionSimulationFailed` (RAIN_403) / their own codes.
  func mapWithdrawalError(_ error: Error) -> RainError {
    let mapped = RainError.from(underlying: error)
    if case .transactionSimulationFailed(let underlying) = mapped {
      return .withdrawalRevertedByNetwork(
        details: "Withdrawal reverted by the network: \(underlying.localizedDescription)"
      )
    }
    return mapped
  }

  /// Rejects withdrawal parameters that cannot produce a valid transaction, before any network
  /// call or signature prompt.
  func validateWithdrawRequest(chainId: Int, amount: Decimal, decimals: Int) throws {
    guard chainId > 0 else {
      throw RainError.invalidConfig(
        details: "Invalid chainId: \(chainId). Must be a positive integer."
      )
    }
    guard amount > 0 else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "amount must be greater than zero"
      )
    }
    guard decimals >= 0 else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "decimals must be non-negative, got \(decimals)"
      )
    }
  }

  /// Builds a withdrawal for `chainId` without broadcasting it — the one pipeline behind
  /// `withdrawCollateral`, `prepareWithdrawal`, and `estimateWithdrawalFee`. `selfPaid`: the
  /// host submits and pays, so every Solana check runs as unsponsored.
  func buildPreparedWithdrawal(
    chainId: Int,
    assetAddresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?,
    selfPaid: Bool = false
  ) async throws -> RainPreparedWithdrawal {
    try validateWithdrawRequest(chainId: chainId, amount: amount, decimals: decimals)

    // Solana withdrawals go through Rain's on-chain collateral program rather than an EVM
    // coordinator contract: core composes the two-instruction transaction (ed25519 proof of
    // Rain's signature + the program's withdraw instruction) and the provider signs it.
    if SolanaChains.isSolana(chainId) {
      let unsigned = try await prepareSolanaWithdrawal(
        chainId: chainId,
        assetAddresses: assetAddresses,
        amount: amount,
        decimals: decimals,
        adminSignature: adminSignature,
        selfPaid: selfPaid
      )
      return .solana(unsigned)
    }

    let (_, parameters) = try await prepareEvmWithdrawal(
      chainId: chainId,
      assetAddresses: assetAddresses,
      amount: amount,
      decimals: decimals,
      adminSignature: adminSignature,
      nonce: nonce
    )
    return .evm(parameters)
  }

  /// Composes a Solana collateral withdrawal. The withdrawal is authorized by Rain's coordinator
  /// executor signing a keccak message off chain, so core composes and the provider only signs.
  func prepareSolanaWithdrawal(
    chainId: Int,
    assetAddresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    selfPaid: Bool = false
  ) async throws -> UnsignedSolanaTransfer {
    let owner = try await walletProvider.getAddress(chainId: chainId)
    let amountBaseUnits = try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
    // Turnkey pre-funds rent only inside a sponsored send.
    let sponsoredFees = !selfPaid && walletProvider.sponsorsFees(chainId: chainId)
    let sponsoredRent = sponsoredFees && walletProvider.sponsorsRent(chainId: chainId)

    return try await solanaWithdrawComposer.composeWithdraw(
      chainId: chainId,
      ownerAddress: owner,
      collateralAddress: assetAddresses.proxyAddress,
      mintAddress: assetAddresses.tokenAddress,
      recipientAddress: assetAddresses.recipientAddress,
      amountBaseUnits: amountBaseUnits,
      adminSignature: adminSignature,
      sponsoredFees: sponsoredFees,
      sponsoredRent: sponsoredRent
    )
  }

  /// Builds EVM withdrawal params: EIP-712 message, admin signature via the backing provider, and
  /// calldata. Returns the wallet address and a complete, submittable transaction.
  func prepareEvmWithdrawal(
    chainId: Int,
    assetAddresses: RainWithdrawAddresses,
    amount: Decimal,
    decimals: Int,
    adminSignature: RainAdminSignature,
    nonce: BigUInt?
  ) async throws -> (walletAddress: String, parameters: RainTransactionParameters) {
    guard let signerProvider = walletProvider as? any RainTypedDataSignerProvider else {
      throw RainError.internalError(
        details: "Current wallet provider does not support EIP-712 signing"
      )
    }

    let walletAddress = try await walletProvider.address()

    // `withdrawAsset` verifies the withdrawal signature against the collateral's admin set, so a
    // non-admin signer reverts on-chain with `InvalidSignature()`. Only a definitive `false`
    // blocks — an unknown result proceeds, so a check that cannot run never blocks a withdrawal.
    if await transactionBuilderService.isCollateralAdmin(
      proxyAddress: assetAddresses.proxyAddress,
      walletAddress: walletAddress,
      chainId: chainId
    ) == false {
      throw RainError.walletNotAuthorized(
        walletAddress: walletAddress,
        proxyAddress: assetAddresses.proxyAddress
      )
    }

    let eip712 = try await WithdrawalBuilder.buildEIP712Message(
      builder: transactionBuilderService,
      chainId: chainId,
      walletAddress: walletAddress,
      addresses: assetAddresses,
      amount: amount,
      decimals: decimals,
      nonce: nonce
    )
    let walletSignatureString = try await signerProvider.signTypedData(
      chainId: chainId,
      walletAddress: walletAddress,
      typedData: eip712.message
    )

    let transactionData = try WithdrawalBuilder.buildWithdrawTransactionData(
      builder: transactionBuilderService,
      addresses: assetAddresses,
      amount: amount,
      decimals: decimals,
      executorSignature: adminSignature,
      walletSalt: eip712.salt,
      walletSignature: walletSignatureString
    )

    let parameters = RainTransactionParameters(
      from: walletAddress,
      to: assetAddresses.controllerAddress,
      value: 0.ethToWei.toHexString,
      data: transactionData
    )

    return (walletAddress, parameters)
  }

  /// Bridges the public result type to the provider port's DTO. The two are field-identical;
  /// collapsing them is a follow-up that would ripple through every adapter and test double.
  func walletParams(_ parameters: RainTransactionParameters) -> WalletTransactionParams {
    WalletTransactionParams(
      from: parameters.from,
      to: parameters.to,
      value: parameters.value,
      data: parameters.data
    )
  }

  /// Estimates total transaction fee (estimated gas × gas price) in native token via the backing provider.
  func estimateTransactionFee(chainId: Int, address: String, params: WalletTransactionParams) async throws -> Decimal {
    guard let estimatingProvider = walletProvider as? any RainTransactionFeeEstimatingProvider else {
      throw RainError.internalError(
        details: "Current wallet provider does not support fee estimation"
      )
    }

    return try await estimatingProvider.estimateTransactionFee(
      chainId: chainId,
      walletAddress: address,
      params: params
    )
  }

}
