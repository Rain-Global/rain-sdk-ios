import Foundation
import Web3

// MARK: - Token approvals (Auth Pull)
//
// The wallet-side prerequisite for Rain's Auth Pull: approve the Rain operator to move USDC from
// the user's wallet, read back what it may still move, and price the approval beforehand. The
// pull itself is Rain's, not the SDK's.
//
// Approvals ride the same generic pipeline as any other send — calldata from
// `TransactionBuilderService`, broadcast through `WalletProvider.sendTransaction` — so
// provider-specific behaviour (Portal/Privy simulation, biometric prompts) applies unchanged.
//
// Every method here refuses to run until the host supplies a `RainAuthPullConfig`, and then
// accepts only that exact operator and the configured token for the chain. An approval is the one
// operation whose damage is invisible afterwards: `approve` succeeds against any address, needs no
// balance, and mines a real allowance whatever it names.
extension RainSdkManager {
  enum ApprovalConfirmation {
    static let attempts = 60
    static let interval: Duration = .seconds(1)
  }

  func approveTokenAllowance(
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?
  ) async throws -> RainTokenApprovalResult {
    do {
      // Configuration errors first (the documented contract), then the provider's chain gate —
      // both before the wallet is touched, so an approval on a chain the provider cannot
      // broadcast on fails closed here rather than at the signing prompt. The fee estimate is
      // deliberately not gated: estimates are reads.
      try validateApprovalRequest(chainId: chainId, contractAddress: contractAddress, spender: spender)
      try walletProvider.requireSendSupport(chainId: chainId)
      let (_, params) = try await buildApproval(
        chainId: chainId,
        contractAddress: contractAddress,
        spender: spender,
        amount: amount
      )
      let hash = try await walletProvider.sendTransaction(chainId: chainId, params: params)
      RainLogger.info("Rain SDK: Approval transaction submitted. Hash: \(hash)")
      return RainTokenApprovalResult(transactionHash: hash)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func getTokenAllowance(
    chainId: Int,
    contractAddress: String,
    spender: String,
    owner: String?
  ) async throws -> RainTokenAllowance {
    do {
      try validateApprovalRequest(chainId: chainId, contractAddress: contractAddress, spender: spender)

      let resolvedOwner: String
      if let owner {
        resolvedOwner = owner
      } else {
        resolvedOwner = try await walletProvider.address()
      }
      guard resolvedOwner.isValidEthereumAddress else {
        throw RainError.invalidConfig(details: "Invalid owner address: \(resolvedOwner)")
      }

      let rawAmount = try await chainReader.getERC20Allowance(
        chainId: chainId,
        tokenAddress: contractAddress,
        owner: resolvedOwner,
        spender: spender
      )
      // Same strictness as the approval: an allowance whose scale is a guess cannot be compared
      // against anything — `covers` would answer from the wrong exponent.
      let resolvedDecimals = try await requireDecimals(
        chainId: chainId, contractAddress: contractAddress
      )

      return RainTokenAllowance(
        chainId: chainId,
        tokenAddress: contractAddress,
        owner: resolvedOwner,
        spender: spender,
        rawAmount: rawAmount,
        decimals: resolvedDecimals
      )
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func estimateApprovalFee(
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?
  ) async throws -> Decimal {
    do {
      let (from, params) = try await buildApproval(
        chainId: chainId,
        contractAddress: contractAddress,
        spender: spender,
        amount: amount
      )
      return try await estimateTransactionFee(chainId: chainId, address: from, params: params)
    } catch is CancellationError {
      // The caller walked away; the generic wrap would call that a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  func confirmTokenAllowance(
    transactionHash: String,
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?,
    owner: String?
  ) async throws -> RainTokenAllowance {
    do {
      try validateApprovalRequest(chainId: chainId, contractAddress: contractAddress, spender: spender)
      // Resolved up front: these fail on configuration, not timing, so retrying them changes nothing.
      let expectedRaw = try await approvalBaseUnits(
        chainId: chainId,
        contractAddress: contractAddress,
        amount: amount
      )
      let resolvedDecimals = try await requireDecimals(
        chainId: chainId, contractAddress: contractAddress
      )
      let resolvedOwner: String
      if let owner {
        resolvedOwner = owner
      } else {
        resolvedOwner = try await walletProvider.address()
      }
      guard resolvedOwner.isValidEthereumAddress else {
        throw RainError.invalidConfig(details: "Invalid owner address: \(resolvedOwner)")
      }

      var receipt: MinedReceipt?
      var lastReadFailure: Error?

      for attempt in 0..<ApprovalConfirmation.attempts {
        if receipt == nil {
          // The approval is already out, so a failed read is a reason to try again, not a verdict
          // on the transaction. Only a malformed hash or missing endpoint (`invalidConfig`) is final.
          let mined: MinedReceipt?
          do {
            mined = try await chainReader.getTransactionReceipt(
              chainId: chainId,
              transactionHash: transactionHash
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            if let rainError = error as? RainError, case .invalidConfig = rainError {
              throw rainError
            }
            RainLogger.warning(
              "Rain SDK: Receipt read for \(transactionHash) failed; retrying: \(error)"
            )
            lastReadFailure = error
            mined = nil
          }
          if let mined, !mined.succeeded {
            throw RainError.transactionSimulationFailed(
              underlying: approvalFailure(
                "Approval transaction reverted on-chain: \(transactionHash)"
              )
            )
          }
          receipt = mined
        }

        if let mined = receipt {
          var rawAmount: BigUInt?
          do {
            rawAmount = try await chainReader.getERC20Allowance(
              chainId: chainId,
              tokenAddress: contractAddress,
              owner: resolvedOwner,
              spender: spender,
              atBlock: mined.blockNumber
            )
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            RainLogger.warning(
              """
              Rain SDK: Allowance read at block \(mined.blockNumber) failed; the node may not have \
              it yet: \(error)
              """
            )
            lastReadFailure = error
          }

          if let rawAmount {
            let allowance = RainTokenAllowance(
              chainId: chainId,
              tokenAddress: contractAddress,
              owner: resolvedOwner,
              spender: spender,
              rawAmount: rawAmount,
              decimals: resolvedDecimals
            )
            try verifyConfirmedAllowance(allowance, expectedRaw: expectedRaw)
            return allowance
          }
        }

        if attempt < ApprovalConfirmation.attempts - 1 {
          try await Task.sleep(for: approvalConfirmationInterval)
        }
      }

      guard let mined = receipt else {
        // Not a failure: the approval may still mine. The hash is what the host resumes from —
        // re-read the allowance or confirm again, never re-approve.
        RainLogger.warning(
          "Rain SDK: Approval \(transactionHash) was not confirmed within the window"
            + (lastReadFailure.map { "; last read failure: \($0)" } ?? "")
        )
        throw RainError.transactionPending(statusId: transactionHash)
      }
      // Mined, but the allowance never read back. Surface the node's own failure where there is
      // one; a generic timeout would hide why every read at that block failed.
      if let cause = lastReadFailure as? RainError {
        throw cause
      }
      throw RainError.networkError(
        underlying: approvalFailure(
          """
          Approval transaction \(transactionHash) mined in block \(mined.blockNumber), but the \
          allowance could not be read at that block before timing out
          """,
          underlying: lastReadFailure
        )
      )
    } catch is CancellationError {
      // A cancelled poll is the caller walking away, not a wallet or network verdict, and the
      // generic wrap would classify it as a provider failure.
      throw CancellationError()
    } catch {
      throw RainError.from(underlying: error)
    }
  }

  /// Carries an approval-path message that has no vendor error behind it, for the `RainError`
  /// cases that wrap an underlying `Error`. `underlying` keeps the failure that caused it, where
  /// there was one, so the message doesn't have to be the whole story.
  private func approvalFailure(_ message: String, underlying: Error? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let underlying {
      userInfo[NSUnderlyingErrorKey] = underlying as NSError
    }
    return NSError(domain: "rain.authpull.approval", code: 0, userInfo: userInfo)
  }

  // MARK: - Internal helpers

  /// Checks the allowance a mined approval actually left behind.
  ///
  /// Deliberately not an equality check. Auth Pull is the feature that *spends* this allowance: an
  /// authorization can pull between the receipt landing and this read, and USDC decrements the
  /// allowance on every `transferFrom` — including a `uint256` max one, which Circle's token does
  /// not special-case. A value below the requested one is therefore an ordinary outcome of a
  /// successful approval, not a failure.
  ///
  /// What is still a genuine failure: a revoke that left a spendable allowance, and an approval
  /// that mined against nothing (a zero allowance where a non-zero one was requested — the shape a
  /// wrong owner, token, or spender produces).
  private func verifyConfirmedAllowance(
    _ allowance: RainTokenAllowance,
    expectedRaw: BigUInt
  ) throws {
    guard expectedRaw != 0 else {
      guard allowance.isZero else {
        throw RainError.internalError(
          details: """
            Revoke mined but \(allowance.spender) still holds an allowance of \(allowance.rawAmount)
            """
        )
      }
      return
    }
    guard !allowance.isZero else {
      throw RainError.internalError(
        details: """
          Approval mined but the allowance for \(allowance.spender) on \(allowance.tokenAddress) \
          is still zero; expected \(expectedRaw)
          """
      )
    }
    if allowance.rawAmount < expectedRaw {
      RainLogger.warning(
        """
        Rain SDK: Allowance is \(allowance.rawAmount), below the approved \(expectedRaw) — an \
        authorization has likely already pulled against it
        """
      )
    }
  }

  /// Builds the `approve` transaction shared by the broadcast and estimate paths, so the fee is
  /// priced against the exact calldata that would be sent.
  private func buildApproval(
    chainId: Int,
    contractAddress: String,
    spender: String,
    amount: Decimal?
  ) async throws -> (from: String, params: WalletTransactionParams) {
    try validateApprovalRequest(chainId: chainId, contractAddress: contractAddress, spender: spender)

    let from = try await walletProvider.address()
    let amountBaseUnits = try await approvalBaseUnits(
      chainId: chainId,
      contractAddress: contractAddress,
      amount: amount
    )

    let data = try await transactionBuilderService.buildERC20ApproveData(
      chainId: chainId,
      contractAddress: contractAddress,
      walletAddress: from,
      spender: spender,
      amount: amountBaseUnits
    )

    let params = WalletTransactionParams(
      from: from,
      to: contractAddress,
      value: 0.ethToWei.toHexString,
      data: data
    )
    return (from, params)
  }

  /// An omitted amount means unlimited, which needs no decimals and so no metadata read. A
  /// supplied amount is scaled by the token's decimals, and `0` is legal — that is a revoke.
  private func approvalBaseUnits(
    chainId: Int,
    contractAddress: String,
    amount: Decimal?
  ) async throws -> BigUInt {
    guard let amount else { return RainTokenAllowance.unlimitedRawAmount }
    guard amount >= 0 else {
      throw RainError.invalidAmount(
        amount: "\(amount)",
        reason: "approval amount must not be negative"
      )
    }
    let resolvedDecimals = try await requireDecimals(
      chainId: chainId, contractAddress: contractAddress
    )
    return try AmountHelpers.toBaseUnits(amount: amount, decimals: resolvedDecimals)
  }

  /// The token's decimals, refusing to guess and refusing to take the caller's word for it.
  ///
  /// The rest of the SDK falls back to 18 when a `decimals()` read fails, which misreports a
  /// balance. On an approval the same guess would *over-approve* a 6-decimal token by 10^12 —
  /// and `approve` succeeds regardless of balance, so no later step would catch it. Failing
  /// loudly is the only safe answer, and it is why the Auth Pull methods take no `decimals`
  /// parameter: the scale comes from the registry or a strict on-chain read, both of which the
  /// SDK trusts.
  func requireDecimals(
    chainId: Int,
    contractAddress: String
  ) async throws -> Int {
    // `decimals()` is whatever the contract says, and the scaling math converts it to `Int16` —
    // which traps rather than throws. The store refuses a value outside 0...77 with
    // `invalidConfig` (uint256 max is ~1.16e77, so one whole unit of a finer token is
    // unrepresentable); an unresolvable token is `tokenNotFound`.
    guard let resolved = try await tokenStore.decimals(chainId: chainId, address: contractAddress)
    else {
      throw RainError.tokenNotFound(token: contractAddress, chainId: chainId)
    }
    return resolved
  }

  /// Rejects approval parameters that cannot produce a valid transaction, before any network
  /// call or signature prompt.
  private func validateApprovalRequest(
    chainId: Int,
    contractAddress: String,
    spender: String
  ) throws {
    guard chainId > 0 else {
      throw RainError.invalidConfig(
        details: "Invalid chainId: \(chainId). Must be a positive integer."
      )
    }
    // SPL delegation is per token account and carries its own semantics, so an ERC-20 approval
    // has no Solana equivalent to fall back on.
    guard !SolanaChains.isSolana(chainId) else {
      throw RainError.internalError(
        details: "Token approvals are EVM-only; chainId=\(chainId) is a Solana chain"
      )
    }
    // Rain's operator and USDC are per environment, and the sandbox and production chain sets are
    // disjoint. Approving on the other environment's chain mines a real allowance that no
    // authorization will ever draw on — on mainnet, at real cost. Nothing downstream would catch
    // it, since `approve` succeeds against any address, so refuse the pairing here.
    guard let operatorAddress = authPullOperator, !authPullTokenAddresses.isEmpty else {
      throw RainError.invalidConfig(
        details: "Auth Pull is disabled. Configure RainSdk.Builder.authPullConfig(_:) first."
      )
    }
    guard authPullChainIds.contains(chainId) else {
      throw RainError.invalidConfig(
        details: """
          chainId=\(chainId) is not an Auth Pull chain for this client \
          (expected one of \(authPullChainIds.sorted().map(String.init).joined(separator: ", "))). \
          Check the RainAuthPullConfig and the RPC endpoints the SDK was built with.
          """
      )
    }
    guard contractAddress.isValidEthereumAddress else {
      throw RainError.invalidConfig(details: "Invalid token contract address: \(contractAddress)")
    }
    guard spender.isValidEthereumAddress else {
      throw RainError.invalidConfig(details: "Invalid spender address: \(spender)")
    }
    guard spender.caseInsensitiveCompare(operatorAddress) == .orderedSame else {
      throw RainError.invalidConfig(
        details: "Spender does not match the configured Auth Pull operator"
      )
    }
    guard let trustedToken = authPullTokenAddresses[chainId] else {
      throw RainError.invalidConfig(
        details: "No Auth Pull token configured for chainId=\(chainId)"
      )
    }
    guard contractAddress.caseInsensitiveCompare(trustedToken) == .orderedSame else {
      throw RainError.invalidConfig(
        details: "Token contract does not match the configured Auth Pull token for chainId=\(chainId)"
      )
    }
  }
}
