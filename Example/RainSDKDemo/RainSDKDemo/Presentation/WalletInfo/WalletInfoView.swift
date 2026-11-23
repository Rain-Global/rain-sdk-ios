import SwiftUI

/// Wallet address + collateral deposit address, each with a QR code and a copy button.
struct WalletInfoView: View {
  @StateObject private var viewModel = WalletInfoViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared
  @State private var copiedAddress: String?

  private var chain: WalletChain { sdkService.selectedChain }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: RainMetrics.s3) {
        if viewModel.isLoading {
          HStack(spacing: RainMetrics.s1) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .rainAccent))
            Text("Loading wallet info...")
              .font(RainFont.meta)
              .tracking(-0.12)
              .foregroundStyle(Color.rainTextMuted)
          }
        }

        if let error = viewModel.errorText {
          RainErrorBanner(text: error)
          RainAsyncButton(title: "Retry", kind: .secondary) {
            await viewModel.fetchWalletInfo(chain: chain)
          }
        }

        // User wallet address (provider-agnostic — Portal, Turnkey, or Privy).
        if !viewModel.walletAddress.isEmpty {
          addressCard(
            title: "\(chain.nativeSymbol) wallet address",
            address: viewModel.walletAddress,
            qr: viewModel.walletQR
          )
        }

        // Collateral deposit address, from the Rain contract for this chain family.
        if !viewModel.collateralAddress.isEmpty {
          addressCard(
            title: "Collateral deposit address",
            address: viewModel.collateralAddress,
            qr: viewModel.collateralQR
          )
        }
      }
      .padding(RainMetrics.s2)
    }
    .rainScreen()
    .navigationTitle("Wallet & QR")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.rainInk, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    // Re-fetch whenever the active chain changes so the screen shows that wallet's address.
    .task(id: chain) { await viewModel.fetchWalletInfo(chain: chain) }
  }

  private func addressCard(title: String, address: String, qr: UIImage?) -> some View {
    let isValid = chain.isValidAddress(address)
    return VStack(alignment: .leading, spacing: RainMetrics.s2) {
      HStack(spacing: RainMetrics.s1) {
        Text(title)
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextPrimary)
        Spacer()
        RainStatusPill(text: isValid ? "Valid" : "Invalid", active: isValid)
      }

      if let qr {
        Image(uiImage: qr)
          .interpolation(.none)
          .resizable()
          .frame(width: 200, height: 200)
          .padding(RainMetrics.s1)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: RainMetrics.rSmall, style: .continuous))
          .frame(maxWidth: .infinity)
          .accessibilityLabel("\(title) QR Code")
      }

      Text(address)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Color.rainTextMuted)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)

      RainAsyncButton(
        title: copiedAddress == address ? "Copied" : "Copy address",
        kind: .secondary
      ) {
        UIPasteboard.general.string = address
        copiedAddress = address
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          if copiedAddress == address { copiedAddress = nil }
        }
      }
    }
    .rainCard()
  }
}

#Preview {
  NavigationStack {
    WalletInfoView()
  }
}
