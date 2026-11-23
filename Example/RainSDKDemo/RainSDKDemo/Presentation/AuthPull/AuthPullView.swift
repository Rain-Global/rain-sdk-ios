import SwiftUI

/// Approves the user's collateral contract to pull USDC from this wallet — the wallet-side
/// prerequisite for Auth Pull — and shows the resulting allowance.
struct AuthPullView: View {
  @StateObject private var viewModel = AuthPullViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared

  /// Which action the confirmation dialog is standing in front of. An approval is irreversible
  /// once mined and, in production, spends real gas to grant a real spend allowance.
  private enum PendingAction: Identifiable {
    case approve
    case revoke

    var id: Self { self }
  }

  @State private var pendingAction: PendingAction?

  private var chain: WalletChain { sdkService.selectedChain }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: RainMetrics.s3) {
        environmentBanner

        if viewModel.supportsAuthPull(chain) {
          allowanceCard
          formCard

          if let error = viewModel.errorText {
            RainErrorBanner(text: error)
          }

          RainAsyncButton(title: "Revoke allowance", kind: .destructive, enabled: !viewModel.isApproving) {
            pendingAction = .revoke
          }

          if let txHash = viewModel.txHash {
            resultCard(txHash: txHash)
          }

          explainer
        } else {
          unsupportedCard
        }
      }
      .padding(RainMetrics.s2)
    }
    .rainScreen()
    .navigationTitle("Auth pull")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.rainInk, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    // Contract and token are per-chain, so re-seed on a chain switch.
    .task(id: chain) { viewModel.onChainChanged(chain) }
    .onChange(of: viewModel.amount) { viewModel.onAmountChanged() }
    .onChange(of: viewModel.isUnlimited) { viewModel.onUnlimitedChanged() }
    .confirmationDialog(
      pendingAction == .revoke ? "Confirm revocation" : "Confirm Auth pull approval",
      isPresented: Binding(
        get: { pendingAction != nil },
        set: { if !$0 { pendingAction = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingAction
    ) { action in
      Button(action == .revoke ? "Revoke" : "Approve", role: action == .revoke ? .destructive : nil) {
        pendingAction = nil
        if action == .revoke {
          viewModel.revoke(chain: chain)
        } else {
          viewModel.approve(chain: chain)
        }
      }
      Button("Cancel", role: .cancel) { pendingAction = nil }
    } message: { action in
      Text(confirmationMessage(for: action))
    }
  }

  /// Spells out exactly what is about to be granted, since the contract and token are not
  /// editable fields and "unlimited" is easy to skim past.
  private func confirmationMessage(for action: PendingAction) -> String {
    let allowance: String
    switch action {
    case .revoke:
      allowance = "zero (revoke)"
    case .approve:
      allowance = viewModel.isUnlimited
        ? "UNLIMITED: all current and future USDC until revoked"
        : "\(viewModel.amount) USDC"
    }
    return """
      Environment: \(SampleEnvironment.displayName)
      Chain: \(chain.displayName) (\(chain.chainId))
      Token: \(viewModel.tokenAddress)
      Collateral contract: \(viewModel.collateralAddress)
      Allowance: \(allowance)
      """
  }

  private var environmentBanner: some View {
    HStack(alignment: .top, spacing: RainMetrics.s1) {
      RainStatusPill(text: SampleEnvironment.displayName, active: SampleEnvironment.isProduction)
      Text(
        SampleEnvironment.isProduction
          ? "This approval uses real USDC and real gas."
          : "Approvals use testnet USDC and testnet gas."
      )
      .font(RainFont.meta)
      .tracking(-0.12)
      .foregroundStyle(SampleEnvironment.isProduction ? Color.rainWarn : Color.rainTextMuted)
    }
  }

  // MARK: - Allowance

  /// Reads the allowance state rather than describing it as a standing permission, so a revoked
  /// wallet does not read as one Rain can still pull from.
  private var allowanceCaption: String {
    guard viewModel.allowanceText != nil else {
      return "What the collateral contract may pull from this wallet."
    }
    if viewModel.isRevokedAllowance {
      return "Revoked. The collateral contract cannot pull from this wallet."
    }
    if viewModel.isUnlimitedAllowance {
      return "The collateral contract may pull any amount from this wallet."
    }
    return "What the collateral contract may still pull from this wallet."
  }

  private var allowanceCard: some View {
    let canRefresh = !viewModel.isLoadingAllowance && !viewModel.isApproving
    return VStack(alignment: .leading, spacing: RainMetrics.s2) {
      HStack {
        Text("Current allowance")
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextPrimary)
        Spacer()
        Button {
          hideKeyboard()
          viewModel.refreshAllowance(chain: chain)
        } label: {
          RainIcon.refresh.view(size: 20, color: canRefresh ? .rainTextPrimary : .rainIconMuted)
        }
        .buttonStyle(.plain)
        .disabled(!canRefresh)
        .accessibilityLabel("Refresh allowance")
      }

      if viewModel.isLoadingAllowance {
        HStack(spacing: RainMetrics.s1) {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .rainAccent))
          Text("Reading allowance...")
            .font(RainFont.meta)
            .tracking(-0.12)
            .foregroundStyle(Color.rainTextMuted)
        }
      } else if let allowance = viewModel.allowanceText {
        Text(viewModel.isUnlimitedAllowance ? allowance : "\(allowance) USDC")
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(viewModel.isUnlimitedAllowance ? Color.rainAccent : Color.rainTextPrimary)
      } else {
        Text("—")
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextMuted)
      }

      Text(allowanceCaption)
        .font(RainFont.meta)
        .tracking(-0.12)
        .foregroundStyle(Color.rainTextMuted)
    }
    .rainCard()
  }

  // MARK: - Form

  private var formCard: some View {
    RainSectionCard(title: "Approve collateral contract") {
      // Read-only: the token is the one the SDK was built with and the contract comes from the Rain
      // API; a typed spender is exactly what Auth Pull must never approve.
      readOnlyAddress(title: "USDC contract", value: viewModel.tokenAddress)
      readOnlyAddress(
        title: "Collateral contract",
        value: viewModel.collateralAddress.isEmpty ? "—" : viewModel.collateralAddress
      )

      Toggle(isOn: $viewModel.isUnlimited) {
        Text("Unlimited approval")
          .font(RainFont.body)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextPrimary)
      }
      .tint(Color.rainAccent)
      .disabled(viewModel.isApproving)

      if !viewModel.isUnlimited {
        RainLabeledField(title: "Amount (USDC)", placeholder: "250", text: $viewModel.amount)
          .disabled(viewModel.isApproving)
        Text("Zero revokes the approval.")
          .font(RainFont.meta)
          .tracking(-0.12)
          .foregroundStyle(Color.rainTextMuted)
      }

      if let fee = viewModel.estimatedFee {
        RainInfoBlock(title: "Estimated network fee") {
          Text(fee)
            .font(RainFont.body)
            .tracking(-0.16)
            .foregroundStyle(Color.rainTextPrimary)
        }
      }

      RainAsyncButton(title: "Estimate fee", kind: .secondary, enabled: !viewModel.isApproving) {
        viewModel.estimateFee(chain: chain)
      }

      // The approval runs in a view-model Task, so the spinner follows `isApproving` rather than
      // the button's own in-flight action (which only opens the confirmation dialog).
      RainAsyncButton(
        title: viewModel.isApproving ? "Approving..." : "Approve contract",
        kind: .primary,
        enabled: !viewModel.isApproving,
        isLoading: viewModel.isApproving
      ) {
        pendingAction = .approve
      }
    }
  }

  // MARK: - Result / status

  private func resultCard(txHash: String) -> some View {
    RainSectionCard(title: "Approval") {
      HStack {
        RainStatusPill(text: viewModel.approvalStatus ?? "Approval submitted", active: viewModel.isApproving)
        Spacer()
      }
      Text(
        viewModel.isApproving
          ? "Waiting for a successful receipt and the exact on-chain allowance."
          : "The receipt and resulting allowance were verified on-chain."
      )
      .font(RainFont.meta)
      .tracking(-0.12)
      .foregroundStyle(Color.rainTextMuted)

      RainInfoBlock(title: "Tx hash") {
        if let url = chain.explorerTxURL(hash: txHash) {
          Link(destination: url) {
            HStack(alignment: .top, spacing: RainMetrics.s1) {
              Text(txHash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.rainAccent)
                .multilineTextAlignment(.leading)
              RainIcon.viewExternal.view(size: 16, color: .rainAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          Text(txHash)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.rainTextBody)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var unsupportedCard: some View {
    RainSectionCard(title: "Auth pull is not available on \(chain.displayName)") {
      Text(
        SampleEnvironment.isProduction
          ? "Production Auth Pull runs on Base and Arbitrum. Switch chains on the home screen."
          : "Sandbox Auth Pull runs on Base Sepolia and Arbitrum Sepolia. Switch chains on the home screen."
      )
      .font(RainFont.meta)
      .tracking(-0.12)
      .lineSpacing(3)
      .foregroundStyle(Color.rainTextMuted)
    }
  }

  private var explainer: some View {
    RainSectionCard(title: "How Auth pull works") {
      Text("""
        Fund this wallet with \(SampleEnvironment.isProduction ? "USDC" : "testnet USDC") and a little \(chain.nativeSymbol) for gas, then approve \
        the collateral contract. When a card authorization arrives, Rain pulls the full amount into \
        that contract — the app does nothing further.
        """)
        .font(RainFont.body)
        .tracking(-0.16)
        .lineSpacing(4)
        .foregroundStyle(Color.rainTextBody)
    }
  }

  private func readOnlyAddress(title: String, value: String) -> some View {
    RainInfoBlock(title: title) {
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Color.rainTextBody)
        .textSelection(.enabled)
    }
  }
}

#Preview {
  NavigationStack {
    AuthPullView()
  }
}
