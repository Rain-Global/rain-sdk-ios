import Foundation
import RainCore
import Web3

/// A collateral token that can be withdrawn.
struct WithdrawTokenOption: Identifiable {
  let name: String
  let symbol: String
  let address: String
  /// `nil` when the SDK could not establish the token's decimals (`RainSdk.tokenMetadata`
  /// returned nil). Such a token is shown but cannot be withdrawn: guessing decimals would scale
  /// the amount by orders of magnitude, so the strict answer is respected here as well.
  let decimals: Int?
  let balance: Decimal

  var id: String { address }

  var displayName: String { symbol.isEmpty ? name : "\(name) (\(symbol))" }

  var isWithdrawable: Bool { decimals != nil }
}

/// Identifies the exact inputs an admin signature was issued for. A cached signature is only
/// reused when the next withdraw targets the same key — preventing a signature minted for a typed
/// amount from being reused by "Withdraw Maximum" (or vice-versa), which would revert.
struct SignatureKey: Equatable {
  let tokenAddress: String
  let amountBaseUnits: String
  let recipientAddress: String
}

/// Withdraws collateral from the Rain contract for the active chain: fetches the admin signature,
/// then builds, signs, and submits through the wallet provider.
@MainActor
final class CollateralWithdrawViewModel: ObservableObject {
  @Published private(set) var walletAddress = ""
  @Published var recipientAddress = ""
  @Published var amount = ""
  @Published private(set) var availableTokens: [WithdrawTokenOption] = []
  @Published private(set) var selectedTokenIndex = -1
  @Published private(set) var isLoadingContract = false
  @Published private(set) var isWithdrawing = false
  @Published private(set) var withdrawResult: String?
  /// Summary of the last `prepareWithdrawal` result — nothing was broadcast.
  @Published private(set) var preparedWithdrawal: String?
  /// Fee from the last `estimateWithdrawalFee` call, in the chain's native token.
  @Published private(set) var estimatedFee: String?
  @Published private(set) var errorText: String?
  /// The chain the loaded contract lives on — drives the explorer link for the result hash.
  @Published private(set) var contractChainId = 0

  private var proxyAddress = ""
  private var controllerAddress = ""
  private var depositAddress: String?
  private var adminAddress = ""
  /// True when the loaded contract lives on a Solana cluster (drives the EVM-only fee estimate).
  @Published private(set) var isSolanaContract = false
  private var adminSignature: RainAdminSignature?
  private var signatureKey: SignatureKey?

  private let session: RainSDKService

  init() {
    self.session = .shared
  }

  var selectedToken: WithdrawTokenOption? {
    availableTokens.indices.contains(selectedTokenIndex) ? availableTokens[selectedTokenIndex] : nil
  }

  private var parsedAmount: Decimal? { Decimal(string: amount) }

  /// True when the typed amount is positive and within the selected token's balance. A tiny
  /// epsilon absorbs display rounding so an exact "max" amount isn't rejected.
  var isAmountValid: Bool {
    guard let token = selectedToken, let value = parsedAmount else { return false }
    return value > 0 && value <= token.balance + Self.epsilon
  }

  /// True when the typed amount exceeds the selected token's available balance.
  var isAmountOverBalance: Bool {
    guard let token = selectedToken, let value = parsedAmount else { return false }
    return value > token.balance + Self.epsilon
  }

  var canWithdrawMaximum: Bool {
    (selectedToken?.balance ?? 0) > 0 && !isWithdrawing
  }

  /// Dry-run actions need the same valid amount a real withdraw does.
  var canDryRun: Bool { isAmountValid && !isWithdrawing }

  private static let epsilon = Decimal(string: "0.000000001") ?? 0

  // MARK: - Input

  // A cached admin signature is bound to a specific (token, amount, recipient) via `signatureKey`.
  // Clearing it on input changes is belt-and-suspenders — executeWithdraw also verifies the key
  // matches before reusing it — so a stale signature is never sent for the wrong amount/recipient.

  func onTokenSelected(_ index: Int) {
    selectedTokenIndex = index
    withdrawResult = nil
    errorText = nil
    invalidateSignature()
  }

  func onAmountChanged(_ value: String) {
    amount = value
    errorText = nil
    invalidateSignature()
  }

  func onRecipientChanged(_ value: String) {
    recipientAddress = value
    invalidateSignature()
  }

  // MARK: - Contract

  func loadContractInfo(chain: WalletChain) async {
    SampleLog.i("Withdraw.contract", "loading contract info chain=\(chain.displayName)")
    isLoadingContract = true
    errorText = nil

    do {
      let client = try session.requireClient()
      let address = try await client.getWalletAddress(chainId: chain.chainId)
      SampleLog.d("Withdraw.contract", "wallet address=\(address)")
      walletAddress = address
      recipientAddress = address

      // The collateral contract comes from the Rain API — the host's call, not the SDK's.
      guard let contract = try await session.fetchCollateralContract(for: chain) else {
        SampleLog.w("Withdraw.contract", "no collateral contract for \(chain.displayName)")
        errorText = "No collateral contract on \(chain.displayName)"
        availableTokens = []
        selectedTokenIndex = -1
        isLoadingContract = false
        return
      }
      SampleLog.i(
        "Withdraw.contract",
        "contract=\(contract.proxyAddress) tokens=\(contract.tokens.count) chainId=\(contract.chainId)"
      )

      proxyAddress = contract.proxyAddress
      controllerAddress = contract.controllerAddress
      depositAddress = contract.depositAddress
      contractChainId = contract.chainId
      isSolanaContract = WalletChain.solanaChainIds.contains(contract.chainId)
      adminAddress = contract.adminAddresses.first ?? ""
      // Token name / symbol / decimals were resolved by the SDK from each address
      // (`RainSdk.tokenMetadata`, via `RainSDKService.fetchCollateralContract(for:)`). A nil
      // `decimals` means the SDK could not establish them; the token is listed but disabled —
      // never guessed, since wrong decimals would scale the withdrawal by orders of magnitude.
      availableTokens = contract.tokens.map { token in
        WithdrawTokenOption(
          name: token.name ?? "Token",
          symbol: token.symbol ?? "",
          address: token.address,
          decimals: token.decimals,
          balance: token.balanceAmount ?? 0
        )
      }
      for token in availableTokens where !token.isWithdrawable {
        SampleLog.w("Withdraw.contract", "decimals unresolved for \(token.address); withdrawal disabled")
      }
      selectedTokenIndex = availableTokens.firstIndex(where: \.isWithdrawable) ?? -1
    } catch {
      SampleLog.e("Withdraw.contract", "failed: \(error.localizedDescription)")
      errorText = error.localizedDescription
    }
    isLoadingContract = false
  }

  // MARK: - Withdraw

  /// Withdraw the full available balance of the selected token.
  func withdrawMaximum() async {
    guard let token = selectedToken else { return }
    await executeWithdraw(amountOverride: token.balance)
  }

  /// Builds the withdrawal without broadcasting it, and shows what came back. The EVM case is a
  /// complete transaction (from/to/value/data); the Solana case is the serialized unsigned
  /// transaction plus the blockhash it was simulated against.
  func prepareWithdrawal(amountOverride: Decimal? = nil) async {
    await runWithdrawFlow(amountOverride: amountOverride, tag: "Withdraw.prepare") { addresses, amount, decimals, signature in
      let prepared = try await self.session.requireClient().prepareWithdrawal(
        chainId: self.contractChainId,
        addresses: addresses,
        amount: amount,
        decimals: decimals,
        adminSignature: signature
      )

      switch prepared {
      case let .evm(parameters):
        self.preparedWithdrawal = """
          EVM transaction
          to: \(parameters.to)
          value: \(parameters.value)
          data: \(Self.truncate(parameters.data))
          """
      case let .solana(transfer):
        self.preparedWithdrawal = """
          Solana transaction
          blockhash: \(transfer.recentBlockhash)
          creates recipient account: \(transfer.createsRecipientAccount)
          tx: \(Self.truncate(transfer.transactionHex))
          """
      }
      // Nothing was broadcast, so the signature is still good — keep it cached.
    }
  }

  /// Estimates the withdrawal fee without broadcasting. EVM only — the SDK throws on a Solana
  /// chain id, which the UI surfaces as-is.
  func estimateFee(amountOverride: Decimal? = nil) async {
    await runWithdrawFlow(amountOverride: amountOverride, tag: "Withdraw.estimate") { addresses, amount, decimals, signature in
      let fee = try await self.session.requireClient().estimateWithdrawalFee(
        chainId: self.contractChainId,
        addresses: addresses,
        amount: amount,
        decimals: decimals,
        adminSignature: signature
      )
      self.estimatedFee = "\(fee.plainString) \(self.nativeSymbol)"
    }
  }

  private static func truncate(_ value: String) -> String {
    value.count > 40 ? "\(value.prefix(24))…\(value.suffix(12))" : value
  }

  private var nativeSymbol: String {
    WalletChain.allCases.first { $0.chainId == contractChainId }?.nativeSymbol ?? ""
  }

  /// Executes a collateral withdrawal. Gas estimation happens inside the SDK as part of sending,
  /// so it isn't surfaced to the caller.
  /// - Parameter amountOverride: when set (e.g. "Withdraw Maximum"), withdraws this amount instead
  ///   of the value typed into the amount field.
  func executeWithdraw(amountOverride: Decimal? = nil) async {
    await runWithdrawFlow(amountOverride: amountOverride, tag: "Withdraw.execute") { addresses, amount, decimals, signature in
      let hash = try await self.session.requireClient().withdrawCollateral(
        chainId: self.contractChainId,
        addresses: addresses,
        amount: amount,
        decimals: decimals,
        adminSignature: signature
      )
      SampleLog.i("Withdraw.execute", "success — txHash=\(hash)")
      self.withdrawResult = hash
      // The signature is consumed by a broadcast; clear it so the next withdraw refetches.
      self.invalidateSignature()
    }
  }

  /// Shared prep for every withdrawal-shaped call: validate the amount, resolve (and cache) the
  /// admin signature for these exact inputs, then hand the pieces to `action`. The three SDK
  /// entry points differ only in what they do with them.
  private func runWithdrawFlow(
    amountOverride: Decimal?,
    tag: String,
    action: (RainWithdrawAddresses, Decimal, Int, RainAdminSignature) async throws -> Void
  ) async {
    guard let token = selectedToken else { return }
    // Strict, like the SDK: no decimals means no withdrawal. The row is disabled in the UI, so
    // this only guards against a stale selection.
    guard let decimals = token.decimals else {
      errorText = "Token decimals could not be resolved; withdrawal disabled for \(token.displayName)"
      return
    }
    guard let rawAmount = amountOverride ?? parsedAmount, rawAmount > 0 else {
      errorText = "Enter a valid amount"
      return
    }
    guard !adminAddress.isEmpty else {
      errorText = "Contract has no admin address"
      return
    }
    // Normalize to the token's precision (round DOWN) so the amount signed for, the base units
    // sent, and the on-chain tx all agree — and so the SDK's scale guard never trips. Rounding
    // down also keeps "Withdraw Maximum" at or below the available balance.
    guard let normalized = normalizedAmount(rawAmount, decimals: decimals) else {
      errorText = "Amount is below the token's minimum unit"
      return
    }
    // UI-side guard: never request more than the token's available balance.
    if normalized.value > token.balance + Self.epsilon {
      errorText = "Amount exceeds available balance (\(token.balance.formatted(places: 6)) \(token.symbol))"
      return
    }

    SampleLog.i(tag, "token=\(token.symbol) amount=\(normalized.value.plainString) to=\(recipientAddress)")
    isWithdrawing = true
    errorText = nil
    withdrawResult = nil
    preparedWithdrawal = nil
    estimatedFee = nil

    // Only reuse the cached signature when it was issued for THIS exact (token, amount,
    // recipient). Reusing matching inputs avoids the "active signature already exists" error on a
    // legitimate retry; a different amount must NOT reuse it (the contract would revert).
    // Lowercasing normalizes EVM hex addresses only — base58 is case-sensitive.
    let key = SignatureKey(
      tokenAddress: isSolanaContract ? token.address : token.address.lowercased(),
      amountBaseUnits: normalized.baseUnits.description,
      recipientAddress: isSolanaContract ? recipientAddress : recipientAddress.lowercased()
    )

    do {
      let signature: RainAdminSignature
      if let cached = adminSignature, signatureKey == key {
        signature = cached
      } else {
        SampleLog.d(tag, "fetching fresh admin signature")
        do {
          // Rain's authorization for this withdrawal comes from the Rain API — the host's call.
          signature = try await session.requireRainApi().fetchAdminSignature(
            chainId: contractChainId,
            tokenAddress: key.tokenAddress,
            amountBaseUnits: normalized.baseUnits.description,
            adminAddress: adminAddress,
            recipientAddress: recipientAddress
          )
        } catch {
          SampleLog.e(tag, "fetchAdminSignature failed: \(error.localizedDescription)")
          throw friendlySignatureError(error)
        }
        // Cache it (with the inputs it's bound to) so a retry after a transient send failure
        // reuses the same signature instead of triggering "active signature already exists".
        adminSignature = signature
        signatureKey = key
      }

      let addresses = RainWithdrawAddresses(
        proxyAddress: proxyAddress,
        controllerAddress: controllerAddress,
        tokenAddress: token.address,
        recipientAddress: recipientAddress,
        depositAddress: depositAddress
      )

      try await action(addresses, normalized.value, decimals, signature)
    } catch {
      SampleLog.e(tag, "failed: \(error.localizedDescription)")
      errorText = error.localizedDescription
    }
    isWithdrawing = false
  }

  /// Clears any cached admin signature. Called whenever an input it is bound to (token, amount,
  /// recipient) changes, so a stale signature is never sent for the wrong amount / recipient.
  private func invalidateSignature() {
    adminSignature = nil
    signatureKey = nil
  }

  /// Rounds a raw amount DOWN to the token's precision and returns both the rounded value and its
  /// exact base-unit representation. Nil when the result rounds to zero.
  private func normalizedAmount(
    _ raw: Decimal,
    decimals: Int
  ) -> (value: Decimal, baseUnits: BigUInt)? {
    var rounded = Decimal()
    var input = raw
    NSDecimalRound(&rounded, &input, decimals, .down)
    guard rounded > 0 else { return nil }
    // Exact base-10 scaling; a Double multiply truncates (e.g. 16.38 * 1e6 == 16_379_999.99…),
    // under-paying the on-chain tx.
    let scaled = NSDecimalNumber(decimal: rounded).multiplying(byPowerOf10: Int16(decimals))
    guard let baseUnits = BigUInt(scaled.stringValue, radix: 10) else { return nil }
    return (rounded, baseUnits)
  }

  /// Maps the raw API error to a clearer hint. The Rain API returns "active signature already
  /// exists" when a previous withdrawal signature for this user is still pending.
  private func friendlySignatureError(_ error: Error) -> Error {
    func wrap(_ message: String) -> Error {
      NSError(
        domain: "CollateralWithdraw", code: -1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
    if case RainApiError.signatureNotReady(_, let retryAfter) = error {
      let hint = retryAfter.map { " — retry in \($0)s" } ?? ""
      return wrap("Withdrawal signature is not ready yet\(hint)")
    }
    let raw = error.localizedDescription
    if raw.range(of: "active signature", options: .caseInsensitive) != nil {
      return wrap(
        "A withdrawal signature is already active for this account. Wait for the previous "
        + "withdrawal to settle (or its signature to expire) before requesting a new one.")
    }
    return wrap("Failed to get signature: \(raw)")
  }
}
