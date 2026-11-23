import SwiftUI

/// Sends the native token or a fungible token on the active chain.
struct SendTokensView: View {
  @StateObject private var viewModel = SendTokensViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared

  private var chain: WalletChain { sdkService.selectedChain }

  private enum TransferKind: String, CaseIterable, Identifiable {
    case native, token
    var id: String { rawValue }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: RainMetrics.s3) {
        // Mode toggle — every chain supports both a native and a token transfer.
        RainSegmentedTabs(
          items: TransferKind.allCases,
          selection: Binding(
            get: { viewModel.isTokenMode ? TransferKind.token : .native },
            set: { viewModel.onSendModeChanged(isToken: $0 == .token) }
          ),
          title: { $0 == .native ? "Native (\(chain.nativeSymbol))" : "\(chain.tokenStandard) token" }
        )

        formCard

        if let error = viewModel.errorText {
          RainErrorBanner(text: error)
        }

        sendButton

        if let txHash = viewModel.txHash {
          resultCard(txHash: txHash)
        }
      }
      .padding(RainMetrics.s2)
    }
    .rainScreen()
    .navigationTitle("Send tokens")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.rainInk, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    // Address defaults differ per chain (contract vs mint), so re-seed the form on a switch.
    .task(id: chain) { viewModel.onChainChanged(chain) }
  }

  private var formCard: some View {
    RainSectionCard(
      title: viewModel.isTokenMode
        ? "Send \(chain.tokenStandard) token"
        : "Send native \(chain.nativeSymbol)"
    ) {
      if viewModel.isTokenMode {
        RainLabeledField(
          title: chain.tokenAddressLabel,
          placeholder: chain.isSolana ? "Mint address (Base58)" : "0x…",
          text: $viewModel.contractAddress
        )
        Text(chain.isSolana
          ? "Decimals come from the mint. If the recipient has no account for this token, one is created and you pay ~0.002 SOL rent."
          : "Decimals are resolved automatically by the SDK")
          .font(RainFont.meta)
          .tracking(-0.12)
          .lineSpacing(3)
          .foregroundStyle(Color.rainTextMuted)
      }

      RainLabeledField(
        title: "Recipient address",
        placeholder: chain.isSolana ? "Base58 address" : "0x…",
        text: $viewModel.recipientAddress
      )

      RainLabeledField(
        title: viewModel.isTokenMode ? "Amount (token units)" : "Amount (\(chain.nativeSymbol))",
        placeholder: "0.001",
        text: $viewModel.amount
      )
    }
  }

  // The view-model send calls return immediately and track their own Task, so the spinner is
  // driven by `isSending` rather than the button's in-flight action.
  private var sendButton: some View {
    RainAsyncButton(
      title: sendButtonTitle,
      kind: .primary,
      enabled: !viewModel.isSending,
      isLoading: viewModel.isSending
    ) {
      if viewModel.isTokenMode {
        viewModel.sendTokenTransfer(chain: chain)
      } else {
        viewModel.sendNative(chain: chain)
      }
    }
  }

  private var sendButtonTitle: String {
    if viewModel.isSending { return "Sending..." }
    return viewModel.isTokenMode
      ? "Send \(chain.tokenStandard)"
      : "Send \(chain.nativeSymbol)"
  }

  private func resultCard(txHash: String) -> some View {
    RainSectionCard(title: "Transaction sent") {
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
}

#Preview {
  NavigationStack {
    SendTokensView()
  }
}
