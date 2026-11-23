import Foundation
import RainCore

/// Drives the Auth Pull prerequisite: approve the user's collateral contract to pull USDC from
/// this wallet, and inspect the allowance before and after.
///
/// The pull itself is Rain's — once the allowance is in place, an authorization moves the funds
/// with no further app involvement.
@MainActor
final class AuthPullViewModel: ObservableObject {
  /// The spender: the user's collateral contract on the chain, read from the Rain API on every
  /// refresh. Displayed, not edited — a spender typed by the user is exactly what Auth Pull must
  /// never approve.
  @Published private(set) var collateralAddress = ""
  @Published private(set) var tokenAddress = WalletChain.firstAuthPullChain?.defaultTokenAddress ?? ""
  @Published var amount = "250"
  @Published var isUnlimited = false

  @Published private(set) var allowanceText: String?
  @Published private(set) var isUnlimitedAllowance = false
  /// Nothing is approved: either never approved, or revoked.
  @Published private(set) var isRevokedAllowance = false
  @Published private(set) var isLoadingAllowance = false
  @Published private(set) var isApproving = false
  @Published private(set) var estimatedFee: String?
  @Published private(set) var txHash: String?
  /// Where the approval has got to: submitted, confirming, or confirmed.
  @Published private(set) var approvalStatus: String?
  @Published private(set) var errorText: String?

  private let session: RainSDKService
  /// The chain the form is seeded for, so re-seeding is idempotent.
  private var seededChain: WalletChain?
  private var readTask: Task<Void, Never>?
  private var estimateTask: Task<Void, Never>?
  private var approvalTask: Task<Void, Never>?
  /// Bumped whenever the form changes or an action starts, so a late reply from a superseded
  /// request cannot write over newer state. `Task.isCancelled` alone misses the case where the
  /// request already finished awaiting and is about to publish.
  private var generation = 0
  /// Which request owns an in-flight flag, per action. Separate from `generation` because that also
  /// moves on a form edit: gating a flag reset on it strands the flag true whenever a request is
  /// superseded rather than completed, and the flag is what disables the controls.
  private var approvalRun = 0
  private var readRun = 0

  init() {
    self.session = .shared
  }

  /// Whether the built SDK will accept an approval on `chain`.
  ///
  /// Read off the client rather than from `WalletChain.supportsAuthPull`, which answers for the
  /// environment: the picker has to answer before an SDK exists, but every screen holding a live
  /// client should gate on what that client actually enforces.
  func supportsAuthPull(_ chain: WalletChain) -> Bool {
    guard let client = session.client else { return false }
    return client.authPullChainIds.contains(chain.chainId)
  }

  func onAmountChanged() {
    generation += 1
    estimateTask?.cancel()
    estimatedFee = nil
    errorText = nil
  }

  func onUnlimitedChanged() {
    generation += 1
    estimateTask?.cancel()
    estimatedFee = nil
    errorText = nil
  }

  /// Seeds the form for `chain` and reads the current allowance. Token and collateral contract
  /// are chain-specific, so switching chains re-fills them.
  func onChainChanged(_ chain: WalletChain) {
    guard seededChain != chain else { return }
    seededChain = chain
    generation += 1
    // Retire any in-flight read now: if the new chain does not support Auth Pull no fresh read
    // will start, and the old chain's answer must not land on this chain's blank card.
    readRun += 1
    readTask?.cancel()
    estimateTask?.cancel()
    approvalTask?.cancel()
    collateralAddress = ""
    tokenAddress = chain.defaultTokenAddress
    allowanceText = nil
    isUnlimitedAllowance = false
    isRevokedAllowance = false
    estimatedFee = nil
    txHash = nil
    approvalStatus = nil
    errorText = nil
    isApproving = false
    // Cleared now rather than whenever the superseded read returns, so the new chain's card does not
    // open on the old chain's spinner.
    isLoadingAllowance = false
    guard supportsAuthPull(chain) else { return }
    refreshAllowance(chain: chain)
  }

  /// Reads `allowance(wallet, collateral contract)` on chain, re-reading the contract from the
  /// Rain API each time so a contract Rain replaced is picked up. Cheap and free — call it on
  /// entry, and again after an approval is mined.
  func refreshAllowance(chain: WalletChain) {
    guard validate(chain: chain, needsContract: false) else { return }

    isLoadingAllowance = true
    errorText = nil

    readTask?.cancel()
    readRun += 1
    let requestRun = readRun
    readTask = Task {
      // The newest read owns the spinner, and clears it however it ends. `getTokenAllowance` is not
      // cancellation-aware, so a superseded read still reaches here and must not clear a spinner it
      // no longer owns.
      defer { if requestRun == readRun { isLoadingAllowance = false } }
      do {
        let contract = try await fetchCollateralAddress(chain: chain)
        guard requestRun == readRun else { return }
        collateralAddress = contract
        let allowance = try await session.requireClient().getTokenAllowance(
          chainId: chain.chainId,
          contractAddress: tokenAddress,
          spender: contract
        )
        SampleLog.i(
          "AuthPull.allowance",
          "raw=\(allowance.rawAmount) decimals=\(allowance.decimals) unlimited=\(allowance.isUnlimited)"
        )
        // `readRun` alone gates publication: an allowance read depends on the chain and wallet,
        // not the amount fields, so an amount edit must not orphan its result — only a newer read
        // (or a chain switch, which starts one) may supersede it.
        guard requestRun == readRun else { return }
        isUnlimitedAllowance = allowance.isUnlimited
        isRevokedAllowance = allowance.isZero
        // An unlimited allowance formats to ~1.16e71 USDC, which is noise — label it instead.
        allowanceText = allowance.isUnlimited ? "Unlimited" : allowance.formatted
      } catch {
        SampleLog.e("AuthPull.allowance", "failed: \(error.localizedDescription)")
        guard requestRun == readRun else { return }
        errorText = "Could not read allowance: \(error.localizedDescription)"
        allowanceText = nil
        isUnlimitedAllowance = false
        isRevokedAllowance = false
      }
    }
  }

  /// Prices the approval without broadcasting it or prompting for a signature.
  func estimateFee(chain: WalletChain) {
    guard validate(chain: chain) else { return }
    // `try?` would flatten the optional and swallow the unlimited case, so catch explicitly.
    let approvalAmount: Decimal?
    do {
      approvalAmount = try resolvedAmount()
    } catch {
      errorText = "Invalid amount"
      return
    }

    errorText = nil
    estimatedFee = nil

    estimateTask?.cancel()
    let requestGeneration = generation
    estimateTask = Task {
      do {
        let fee = try await session.requireClient().estimateApprovalFee(
          chainId: chain.chainId,
          contractAddress: tokenAddress,
          spender: collateralAddress,
          amount: approvalAmount
        )
        SampleLog.i("AuthPull.fee", "estimate=\(fee) \(chain.nativeSymbol)")
        guard requestGeneration == generation else { return }
        estimatedFee = "\(fee) \(chain.nativeSymbol)"
      } catch {
        SampleLog.e("AuthPull.fee", "failed: \(error.localizedDescription)")
        guard requestGeneration == generation else { return }
        errorText = "Fee estimate failed: \(error.localizedDescription)"
      }
    }
  }

  /// Submits the approval, then waits for a successful receipt and reads back the allowance that
  /// actually landed rather than the one that was requested.
  func approve(chain: WalletChain) {
    guard validate(chain: chain) else { return }
    // `try?` would flatten the optional and swallow the unlimited case, so catch explicitly.
    let approvalAmount: Decimal?
    do {
      approvalAmount = try resolvedAmount()
    } catch {
      errorText = "Invalid amount"
      return
    }
    submitApproval(chain: chain, amount: approvalAmount)
  }

  /// Revokes by approving zero — the same call, with an explicit zero amount.
  func revoke(chain: WalletChain) {
    guard validate(chain: chain) else { return }
    submitApproval(chain: chain, amount: 0)
  }

  private func submitApproval(chain: WalletChain, amount approvalAmount: Decimal?) {
    SampleLog.i(
      "AuthPull.approve",
      "token=\(tokenAddress) spender=\(collateralAddress) amount=\(approvalAmount.map(String.init(describing:)) ?? "unlimited")"
    )
    generation += 1
    // An approval supersedes any in-flight read; the confirmed allowance is published below. The
    // superseded read no longer owns the spinner, so clear it here or it never clears.
    readRun += 1
    isLoadingAllowance = false
    readTask?.cancel()
    estimateTask?.cancel()
    approvalTask?.cancel()
    let requestGeneration = generation
    approvalRun += 1
    let requestRun = approvalRun
    isApproving = true
    errorText = nil
    txHash = nil
    approvalStatus = "Submitting approval"

    approvalTask = Task {
      defer { if requestRun == approvalRun { isApproving = false } }
      do {
        let client = try session.requireClient()
        let result = try await client.approveTokenAllowance(
          chainId: chain.chainId,
          contractAddress: tokenAddress,
          spender: collateralAddress,
          amount: approvalAmount
        )
        SampleLog.i("AuthPull.approve", "success txHash=\(result.transactionHash)")
        guard requestGeneration == generation else { return }
        txHash = result.transactionHash
        approvalStatus = "Pending network confirmation"

        let confirmed = try await client.confirmTokenAllowance(
          transactionHash: result.transactionHash,
          chainId: chain.chainId,
          contractAddress: tokenAddress,
          spender: collateralAddress,
          amount: approvalAmount
        )
        SampleLog.i("AuthPull.approve", "confirmed allowance=\(confirmed.rawAmount)")
        guard requestGeneration == generation else { return }
        approvalStatus = "Confirmed on-chain"
        allowanceText = confirmed.isUnlimited ? "Unlimited" : confirmed.formatted
        isUnlimitedAllowance = confirmed.isUnlimited
        isRevokedAllowance = confirmed.isZero
      } catch {
        SampleLog.e("AuthPull.approve", "failed: \(error.localizedDescription)")
        guard requestGeneration == generation else { return }
        approvalStatus = "Approval not confirmed"
        errorText = "Approval failed or was not confirmed: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Helpers

  private struct InvalidAmount: Error {}

  /// The amount to approve, where `nil` means unlimited — what Rain recommends, so the user never
  /// has to re-approve. Throws rather than returning a double optional.
  private func resolvedAmount() throws -> Decimal? {
    if isUnlimited { return nil }
    // `Decimal(string:)` stops at the first character it cannot read, so "12abc" would parse as 12
    // rather than fail. Require the whole field to be a number.
    let trimmed = amount.trimmingCharacters(in: .whitespaces)
    guard trimmed.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil,
          let value = Decimal(string: trimmed) else { throw InvalidAmount() }
    return value
  }

  /// The collateral contract on exactly this chain: Rain provisions one per chain, and approving
  /// another chain's contract would grant an allowance nothing pulls through.
  private func fetchCollateralAddress(chain: WalletChain) async throws -> String {
    let contracts = try await session.requireRainApi().fetchCollateralContracts()
    guard let contract = contracts.first(where: { $0.chainId == chain.chainId }) else {
      throw NSError(
        domain: "RainSDKDemo", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No collateral contract on \(chain.displayName)"]
      )
    }
    return contract.proxyAddress
  }

  private func validate(chain: WalletChain, needsContract: Bool = true) -> Bool {
    guard supportsAuthPull(chain) else {
      errorText = "Auth Pull is not available on \(chain.displayName)"
      return false
    }
    guard chain.isValidAddress(tokenAddress) else {
      errorText = "Token address is not a valid \(chain.displayName) address"
      return false
    }
    guard !needsContract || chain.isValidAddress(collateralAddress) else {
      errorText = "No collateral contract loaded for \(chain.displayName). Tap Refresh."
      return false
    }
    return true
  }
}
