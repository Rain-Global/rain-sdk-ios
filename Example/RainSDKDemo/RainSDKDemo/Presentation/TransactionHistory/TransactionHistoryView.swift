import SwiftUI
import RainCore

/// Transaction history for the active chain, each row labelled Send / Receive / Self.
struct TransactionHistoryView: View {
  @StateObject private var viewModel = TransactionHistoryViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared
  @State private var copiedTokenAddress: String?

  private var chain: WalletChain { sdkService.selectedChain }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: RainMetrics.s3) {
        RainAsyncButton(
          title: "Refresh (\(chain.nativeSymbol))",
          kind: .secondary,
          enabled: !viewModel.isLoading
        ) {
          await viewModel.fetchTransactions(chain: chain)
        }

        if viewModel.isLoading {
          HStack(spacing: RainMetrics.s1) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: .rainAccent))
            Text("Loading transactions...")
              .font(RainFont.meta)
              .tracking(-0.12)
              .foregroundStyle(Color.rainTextMuted)
          }
        }

        if let error = viewModel.errorText {
          RainErrorBanner(text: error)
        }

        // An empty list is expected for a fresh wallet, not a failure: history lists sends from
        // this wallet on the selected network (plus receives where the provider's source has them).
        if !viewModel.isLoading && viewModel.transactions.isEmpty && viewModel.errorText == nil {
          VStack(alignment: .leading, spacing: RainMetrics.s1) {
            Text("No transactions found on \(chain.displayName).")
              .font(RainFont.body)
              .tracking(-0.16)
              .foregroundStyle(Color.rainTextPrimary)
            Text("History lists transactions sent from this wallet on the selected network. "
              + "Sends on other chains, or transfers received from someone else, won't appear here.")
              .font(RainFont.meta)
              .tracking(-0.12)
              .lineSpacing(3)
              .foregroundStyle(Color.rainTextMuted)
          }
          .rainCard()
        }

        if !viewModel.transactions.isEmpty {
          historyCard
        }
      }
      .padding(RainMetrics.s2)
    }
    .rainScreen()
    .navigationTitle("Transaction history")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.rainInk, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    // Re-fetch whenever the active chain changes.
    .task(id: chain) { await viewModel.fetchTransactions(chain: chain) }
  }

  private var historyCard: some View {
    VStack(spacing: 0) {
      // Indexed on purpose: a provider row can carry a blank `uniqueId`, and duplicate ids
      // break `ForEach` identity.
      ForEach(Array(viewModel.transactions.enumerated()), id: \.offset) { index, tx in
        if index > 0 {
          Divider().overlay(Color.rainBorder)
        }
        transactionRow(tx)
      }
    }
    .rainCard()
  }

  private func transactionRow(_ tx: RainTransaction) -> some View {
    // Solana history rows carry the Turnkey status id, not an explorer-resolvable signature, so
    // the hash is shown plainly (no link) on Solana.
    let explorerLinkable = !chain.isSolana
    let explorerURL = chain.explorerTxURL(hash: tx.hash)
    let direction = directionLabel(tx)

    return HStack(alignment: .top, spacing: RainMetrics.s2) {
      (direction == "Send" ? RainIcon.sendTokens : RainIcon.history)
        .view(size: 20, color: .rainIconMuted)

      VStack(alignment: .leading, spacing: RainMetrics.s1) {
        HStack(alignment: .firstTextBaseline, spacing: RainMetrics.s1) {
          Text(direction ?? "Transaction")
            .font(RainFont.label)
            .tracking(-0.16)
            .foregroundStyle(Color.rainTextPrimary)
          Spacer(minLength: RainMetrics.s1)
          amountText(tx)
        }

        if let status = tx.metadata?.status {
          RainStatusPill(
            text: status.capitalized,
            active: ["confirmed", "finalized"].contains(status.lowercased())
          )
        }

        if let formatted = formattedTimestamp(tx.timestamp) {
          metaText(formatted)
        }

        if explorerLinkable, let explorerURL {
          Link(destination: explorerURL) {
            Text(truncateHash(tx.hash))
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(Color.rainAccent)
          }
        } else {
          Text(truncateHash(tx.hash))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.rainTextMuted)
        }

        metaText("From \(truncateAddress(tx.from)) to \(truncateAddress(tx.to ?? "—"))")

        if let tokenAddress = tx.tokenAddress {
          HStack(spacing: RainMetrics.s1) {
            metaText("Token \(truncateAddress(tokenAddress))")
            Button {
              UIPasteboard.general.string = tokenAddress
              copiedTokenAddress = tokenAddress
              Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedTokenAddress == tokenAddress { copiedTokenAddress = nil }
              }
            } label: {
              (copiedTokenAddress == tokenAddress ? RainIcon.valid : RainIcon.copy)
                .view(size: 16, color: copiedTokenAddress == tokenAddress ? .rainSuccess : .rainIconMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy token address")
          }
        }

        // Explorer link only where the hash is a real on-chain signature.
        if explorerLinkable, let explorerURL {
          Link(destination: explorerURL) {
            HStack(spacing: 4) {
              RainIcon.viewExternal.view(size: 16, color: .rainAccent)
              Text("View on \(chain.explorerName)")
                .font(RainFont.meta)
                .tracking(-0.12)
                .foregroundStyle(Color.rainAccent)
            }
          }
        }
      }
    }
    .padding(.vertical, RainMetrics.s1)
  }

  @ViewBuilder
  private func amountText(_ tx: RainTransaction) -> some View {
    if let value = tx.value, value != 0 {
      // Only a transfer with no token address is denominated in the native symbol. A token
      // transfer whose symbol is unknown (SPL names live in off-chain metadata) shows the bare
      // amount, identified by the token address beneath it — labelling it "SOL" would name the
      // wrong asset entirely.
      let unit = tx.asset ?? (tx.tokenAddress == nil ? chain.nativeSymbol : nil)
      Text([value.plainString, unit].compactMap { $0 }.joined(separator: " "))
        .font(RainFont.label)
        .tracking(-0.16)
        .monospacedDigit()
        .foregroundStyle(Color.rainTextPrimary)
        .multilineTextAlignment(.trailing)
    }
  }

  private func metaText(_ text: String) -> some View {
    Text(text)
      .font(RainFont.meta)
      .tracking(-0.12)
      .foregroundStyle(Color.rainTextMuted)
  }

  private func directionLabel(_ tx: RainTransaction) -> String? {
    guard let wallet = viewModel.walletAddress else { return nil }
    let isSend = tx.from.caseInsensitiveCompare(wallet) == .orderedSame
    let isReceive = tx.to?.caseInsensitiveCompare(wallet) == .orderedSame
    switch (isSend, isReceive) {
    case (true, true): return "Self"
    case (true, false): return "Send"
    case (false, true): return "Receive"
    default: return nil
    }
  }

  private func formattedTimestamp(_ timestamp: String?) -> String? {
    guard let timestamp, !timestamp.isEmpty else { return nil }
    let withFractions = ISO8601DateFormatter()
    withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = withFractions.date(from: timestamp) ?? plain.date(from: timestamp) else {
      return timestamp
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private func truncateHash(_ hash: String) -> String {
    hash.count > 20 ? "\(hash.prefix(12))…\(hash.suffix(6))" : hash
  }

  private func truncateAddress(_ address: String) -> String {
    address.count > 14 ? "\(address.prefix(6))…\(address.suffix(6))" : address
  }
}

#Preview {
  NavigationStack {
    TransactionHistoryView()
  }
}
