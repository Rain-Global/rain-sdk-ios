import SwiftUI

/// Withdraws collateral from the Rain contract for the active chain.
struct CollateralWithdrawView: View {
  @StateObject private var viewModel = CollateralWithdrawViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared

  private var chain: WalletChain { sdkService.selectedChain }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: RainMetrics.s3) {
        if viewModel.isLoadingContract {
          HStack(spacing: RainMetrics.s1) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .rainAccent))
            Text("Loading contract info...")
              .font(RainFont.meta)
              .tracking(-0.12)
              .foregroundStyle(Color.rainTextMuted)
          }
        }

        if let error = viewModel.errorText {
          RainErrorBanner(text: error)
        }

        if !viewModel.availableTokens.isEmpty {
          tokenCard
          withdrawalCard

          // Dry-run results — neither of these broadcast anything.
          if let fee = viewModel.estimatedFee {
            RainInfoBlock(title: "Estimated fee") {
              Text(fee)
                .font(RainFont.body)
                .tracking(-0.16)
                .foregroundStyle(Color.rainTextPrimary)
                .textSelection(.enabled)
            }
          }
          if let prepared = viewModel.preparedWithdrawal {
            RainInfoBlock(title: "Prepared (not broadcast)") {
              Text(prepared)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.rainTextBody)
                .textSelection(.enabled)
              Text("A Solana blockhash is valid ~60-90s — submit promptly or re-prepare.")
                .font(RainFont.meta)
                .tracking(-0.12)
                .foregroundStyle(Color.rainTextMuted)
            }
          }
          if let txHash = viewModel.withdrawResult {
            resultCard(txHash: txHash)
          }
        }
      }
      .padding(RainMetrics.s2)
    }
    .rainScreen()
    .navigationTitle("Collateral withdraw")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.rainInk, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    // Re-load whenever the active chain changes so the screen shows that chain's contract.
    .task(id: chain) { await viewModel.loadContractInfo(chain: chain) }
  }

  // MARK: - Token selection

  private var tokenCard: some View {
    RainSectionCard(title: "Select token") {
      VStack(spacing: 0) {
        ForEach(Array(viewModel.availableTokens.enumerated()), id: \.element.id) { index, token in
          if index > 0 {
            Divider().overlay(Color.rainBorder)
          }
          tokenRow(token, selected: index == viewModel.selectedTokenIndex) {
            viewModel.onTokenSelected(index)
          }
        }
      }
    }
  }

  private func tokenRow(
    _ token: WithdrawTokenOption,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: RainMetrics.s2) {
        RainIcon.tokenRow.view(size: 20, color: selected ? .rainAccent : .rainIconMuted)

        VStack(alignment: .leading, spacing: 2) {
          Text(token.displayName)
            .font(RainFont.label)
            .tracking(-0.16)
            .foregroundStyle(Color.rainTextPrimary)
          Text("Balance: \(token.balance.formatted(places: 2))")
            .font(RainFont.meta)
            .tracking(-0.12)
            .foregroundStyle(Color.rainTextMuted)
          if !token.isWithdrawable {
            // The SDK could not resolve this token's decimals (`tokenMetadata` returned nil).
            // Guessing would scale the amount by orders of magnitude, so the token stays
            // visible but cannot be withdrawn — the behaviour a host should copy.
            Text("Decimals unknown — withdrawal disabled")
              .font(RainFont.meta)
              .tracking(-0.12)
              .foregroundStyle(Color.rainWarn)
          }
        }

        Spacer(minLength: 0)

        if selected {
          RainIcon.valid.view(size: 16, color: .rainAccent)
        }
      }
      .opacity(token.isWithdrawable ? 1 : 0.55)
      .padding(.vertical, RainMetrics.s2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!token.isWithdrawable)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: - Withdrawal

  private var withdrawalCard: some View {
    RainSectionCard(title: "Withdrawal") {
      RainLabeledField(
        title: "Recipient address",
        placeholder: "0x…",
        text: Binding(
          get: { viewModel.recipientAddress },
          set: { viewModel.onRecipientChanged($0) }
        )
      )

      amountField

      // Both dry-run actions build the withdrawal exactly as "Withdraw" would — signing EIP-712 and
      // reading the collateral's admin set — but broadcast nothing.
      RainAsyncButton(
        title: "Estimate fee",
        kind: .secondary,
        // EVM only: the SDK rejects a Solana chain id for fee estimation.
        enabled: viewModel.canDryRun && !viewModel.isSolanaContract
      ) {
        await viewModel.estimateFee()
      }

      RainAsyncButton(title: "Prepare withdrawal", kind: .secondary, enabled: viewModel.canDryRun) {
        await viewModel.prepareWithdrawal()
      }

      // Gas estimation also happens in the background as part of the withdraw, so "Estimate fee"
      // above is optional. "Withdraw maximum" withdraws the full available balance.
      RainAsyncButton(title: "Withdraw maximum", kind: .secondary, enabled: viewModel.canWithdrawMaximum) {
        await viewModel.withdrawMaximum()
      }

      RainAsyncButton(
        title: viewModel.isWithdrawing ? "Withdrawing..." : "Withdraw",
        kind: .primary,
        enabled: viewModel.isAmountValid && !viewModel.isWithdrawing
      ) {
        await viewModel.executeWithdraw()
      }
    }
  }

  private var amountField: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s1) {
      RainLabeledField(
        title: "Amount to withdraw",
        placeholder: "e.g. 1.5",
        text: Binding(
          get: { viewModel.amount },
          set: { viewModel.onAmountChanged($0) }
        )
      )

      if let token = viewModel.selectedToken {
        if viewModel.isAmountOverBalance {
          Text("Amount exceeds available balance (\(token.balance.formatted(places: 6)) \(token.symbol))")
            .font(RainFont.meta)
            .tracking(-0.12)
            .foregroundStyle(Color.rainDanger)
        } else {
          Text("Available: \(token.balance.formatted(places: 6)) \(token.symbol)")
            .font(RainFont.meta)
            .tracking(-0.12)
            .foregroundStyle(Color.rainTextMuted)
        }
      }
    }
  }

  // MARK: - Result

  private func resultCard(txHash: String) -> some View {
    RainSectionCard(title: "Withdrawal successful") {
      RainInfoBlock(title: "Tx hash") {
        // Link to the explorer for the contract's actual chain (Base Sepolia → Basescan), not a
        // hardcoded one.
        let contractChain = WalletChain.from(chainId: viewModel.contractChainId) ?? .baseSepolia
        if let url = contractChain.explorerTxURL(hash: txHash) {
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
}

#Preview {
  NavigationStack {
    CollateralWithdrawView()
  }
}
