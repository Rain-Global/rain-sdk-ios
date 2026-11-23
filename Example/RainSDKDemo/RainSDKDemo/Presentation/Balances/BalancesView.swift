import SwiftUI

/// Two cards: the Rain collateral wallet (balances from the API) and the internal wallet
/// (balances read on-chain).
struct BalancesView: View {
  @StateObject private var viewModel = BalancesViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared

  private var chain: WalletChain { sdkService.selectedChain }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: RainMetrics.s3) {
        collateralCard
        internalWalletCard
      }
      .padding(RainMetrics.s2)
    }
    .rainScreen()
    .navigationTitle("Balances")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.rainInk, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task(id: chain) { await viewModel.loadWalletAddress(chain: chain) }
  }

  // MARK: - Collateral wallet

  private var collateralCard: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s2) {
      walletHeader(
        icon: .withdraw,
        title: "Collateral wallet",
        address: viewModel.collateralWalletAddress
      )

      RainInfoBlock(title: "Will fetch") {
        bullet("All token balances in this wallet")
      }

      RainAsyncButton(title: "Fetch", kind: .secondary, enabled: !viewModel.isCollateralLoading) {
        await viewModel.fetchCollateralBalances(chain: chain)
      }

      if let error = viewModel.collateralError {
        RainErrorBanner(text: error)
      }

      if !viewModel.collateralBalances.isEmpty {
        RainSectionLabel(text: "Results")
        VStack(spacing: 0) {
          ForEach(Array(viewModel.collateralBalances.enumerated()), id: \.element.id) { index, token in
            if index > 0 { rowDivider }
            balanceRow(
              icon: .tokenRow,
              iconColor: .rainIconMuted,
              label: token.symbol,
              value: token.balance.formatted(places: 2),
              subtitle: token.displayAddress
            )
          }
        }
      }
    }
    .rainCard()
  }

  // MARK: - Internal wallet

  private var internalWalletCard: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s2) {
      walletHeader(
        icon: .balances,
        title: "Internal wallet",
        address: viewModel.internalWalletAddress
      )

      // Token discovery works on every chain: ERC-20s on EVM, SPL tokens on Solana.
      RainInfoBlock(title: "Will fetch") {
        bullet("\(chain.nativeSymbol) — native token")
        bullet("Every \(chain.tokenStandard) token with a balance > 0 (auto-discovered)")
      }

      RainAsyncButton(title: "Fetch", kind: .secondary, enabled: !viewModel.isLoading) {
        await viewModel.fetchBalances(chain: chain)
      }

      if let error = viewModel.errorMessage {
        RainErrorBanner(text: error)
      }

      if viewModel.nativeBalance != nil || !viewModel.walletTokenBalances.isEmpty {
        RainSectionLabel(text: "Results")

        if let native = viewModel.nativeBalance {
          balanceRow(
            icon: .nativeToken,
            iconColor: .rainAccent,
            label: "Native (\(chain.nativeSymbol))",
            value: native
          )
        }

        if viewModel.walletTokenBalances.isEmpty {
          RainInfoBlock {
            Text("No \(chain.tokenStandard) tokens with a balance > 0.")
              .font(RainFont.body)
              .tracking(-0.16)
              .foregroundStyle(Color.rainTextMuted)
          }
        } else {
          RainSectionLabel(text: "Tokens with a balance")
          VStack(spacing: 0) {
            ForEach(Array(viewModel.walletTokenBalances.enumerated()), id: \.element.id) { index, token in
              if index > 0 { rowDivider }
              balanceRow(
                icon: .tokenRow,
                iconColor: .rainIconMuted,
                label: token.displayName,
                // The unit is always stated: an SPL mint has no on-chain symbol, so an
                // unregistered token is named by its mint rather than showing a bare number.
                value: "\(token.formattedBalance) \(token.displayUnit)",
                subtitle: "\(chain.tokenAddressLabel): \(token.address)"
              )
            }
          }
        }
      }
    }
    .rainCard()
  }

  // MARK: - Building blocks

  private func walletHeader(icon: RainIcon, title: String, address: String) -> some View {
    HStack(spacing: RainMetrics.s2) {
      icon.view(size: 22, color: .rainAccent)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextPrimary)
        Text(address.isEmpty ? "—" : formatAddress(address))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(Color.rainTextMuted)
      }

      Spacer()
    }
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: RainMetrics.s1) {
      Circle()
        .fill(Color.rainIconMuted)
        .frame(width: 6, height: 6)
        .padding(.top, 7)
      Text(text)
        .font(RainFont.body)
        .tracking(-0.16)
        .foregroundStyle(Color.rainTextBody)
    }
  }

  private var rowDivider: some View {
    Divider().overlay(Color.rainBorder)
  }

  private func balanceRow(
    icon: RainIcon,
    iconColor: Color,
    label: String,
    value: String,
    subtitle: String? = nil
  ) -> some View {
    HStack(spacing: RainMetrics.s2) {
      icon.view(size: 20, color: iconColor)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextPrimary)
        if let subtitle {
          Text(subtitle)
            .font(RainFont.meta)
            .tracking(-0.12)
            .foregroundStyle(Color.rainTextMuted)
        }
      }
      Spacer(minLength: RainMetrics.s1)
      Text(value)
        .font(RainFont.label)
        .tracking(-0.16)
        .monospacedDigit()
        .foregroundStyle(Color.rainTextPrimary)
        .multilineTextAlignment(.trailing)
    }
    .padding(.vertical, RainMetrics.s1)
  }
}

#Preview {
  NavigationStack {
    BalancesView()
  }
}
