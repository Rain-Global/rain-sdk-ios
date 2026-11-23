import SwiftUI

/// Root screen: pick a wallet provider, authenticate, initialize Rain, then open a feature.
struct HomeView: View {
  @StateObject private var viewModel = HomeViewModel()
  @ObservedObject private var sdkService = RainSDKService.shared

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: RainMetrics.s3) {
          Text("Rain SDK showcase")
            .font(RainFont.title)
            .tracking(-0.72)
            .foregroundStyle(Color.rainTextPrimary)

          modeSelector

          // Rain API credentials are independent of the wallet provider: they authenticate
          // contract / signature calls to the Rain dev API, so they live in their own card
          // shown in every mode.
          rainApiSection

          switch viewModel.mode {
          case .portal: portalSection
          case .turnkey: turnkeySection
          case .privy: privySection
          case .rainWallet: rainWalletSection
          }

          // Stays visible when the session is dead so the hidden feature grid is explained.
          if let status = sdkService.sessionStatus {
            sessionSection(status)
          }

          let sessionUsable = sdkService.sessionStatus?.health != .dead
          if viewModel.isRecovered && sessionUsable {
            chainSelector
            featureGrid
          }
          if viewModel.isRecovered {
            RainAsyncButton(title: "Clear session", kind: .destructive, enabled: !viewModel.isLoading) {
              await viewModel.clearSession()
            }
          }

          RainStatusLog(text: viewModel.statusText)
        }
        .padding(RainMetrics.s2)
      }
      .rainScreen()
      .toolbarBackground(Color.rainInk, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
    }
  }

  // MARK: - Mode selector

  private var modeSelector: some View {
    RainSegmentedTabs(
      items: WalletMode.allCases,
      selection: Binding(
        get: { viewModel.mode },
        set: { viewModel.onModeChanged($0) }
      ),
      title: { $0.rawValue },
      // Locked while a provider is resolved so the session card always describes `mode`.
      isDisabled: viewModel.isInitialized || sdkService.sessionStatus != nil
    )
  }

  // MARK: - Rain API

  private var rainApiSection: some View {
    RainSectionCard(title: "Rain API credentials") {
      RainLabeledField(title: "Rain API key", placeholder: "Enter Rain API key", text: $viewModel.rainApiKey)
      RainLabeledField(title: "Rain user ID", placeholder: "Enter Rain user ID", text: $viewModel.userId)
    }
  }

  // MARK: - Portal

  private var portalSection: some View {
    RainSectionCard(title: "Portal MPC configuration") {
      RainLabeledField(
        title: "Portal session token",
        placeholder: "Enter session token",
        text: $viewModel.sessionToken
      )

      RainAsyncButton(
        title: viewModel.isInitialized ? "SDK initialized" : "Initialize SDK",
        enabled: viewModel.canInitializePortal
      ) {
        await viewModel.initializeSdk()
      }
    }
  }

  // MARK: - Turnkey

  private var turnkeySection: some View {
    RainSectionCard(title: "Turnkey configuration, email OTP") {
      RainLabeledField(
        title: "Parent organization ID",
        placeholder: "your-turnkey-parent-org-id",
        text: $viewModel.turnkeyOrgId
      )
      .disabled(viewModel.turnkeyOtpId != nil)

      RainLabeledField(
        title: "Auth proxy config ID",
        placeholder: "auth proxy config id",
        text: $viewModel.turnkeyAuthProxyConfigId
      )
      .disabled(viewModel.turnkeyOtpId != nil)

      RainLabeledField(title: "Email", placeholder: "you@example.com", text: $viewModel.turnkeyEmail)
        .disabled(viewModel.turnkeyOtpId != nil)

      RainAsyncButton(
        title: viewModel.turnkeyOtpId != nil ? "OTP sent" : "Init Turnkey & send OTP",
        enabled: viewModel.canSendTurnkeyOtp
      ) {
        await viewModel.sendTurnkeyOtp()
      }

      if viewModel.turnkeyOtpId != nil {
        RainLabeledField(title: "OTP code", placeholder: "123456", text: $viewModel.turnkeyOtpCode)
          .disabled(viewModel.turnkeySessionActive)

        RainAsyncButton(
          title: viewModel.turnkeySessionActive ? "Session active" : "Verify & log in",
          enabled: viewModel.canVerifyTurnkeyOtp
        ) {
          await viewModel.verifyTurnkeyOtp()
        }
      }

      if viewModel.turnkeySessionActive {
        RainAsyncButton(
          title: viewModel.isInitialized ? "Rain initialized" : "Initialize Rain with Turnkey",
          enabled: !viewModel.isLoading && !viewModel.isInitialized
        ) {
          await viewModel.initializeRainWithTurnkey()
        }
      }
    }
  }

  // MARK: - Rain Wallet

  private var rainWalletSection: some View {
    RainSectionCard(title: "Rain Wallet sign-in") {
      // Backend identity is embedded in the SDK — only the login contact is needed. On a live
      // session the same inputs name a contact to ATTACH to the account (see below).
      let contactLocked = viewModel.rainWalletSessionActive
        ? viewModel.rainWalletAttachCodeSent : viewModel.rainWalletOtpSent
      RainSegmentedTabs(
        items: HomeViewModel.RainWalletContactKind.allCases,
        selection: $viewModel.rainWalletContactKind,
        title: { $0.rawValue },
        isDisabled: contactLocked
      )

      if viewModel.rainWalletUsePhone {
        RainLabeledField(title: "Phone", placeholder: "+1 555 123 4567", text: $viewModel.rainWalletPhone)
          .disabled(contactLocked)
      } else {
        RainLabeledField(title: "Email", placeholder: "you@example.com", text: $viewModel.rainWalletEmail)
          .disabled(contactLocked)
      }

      // Gone once the session is active — there is nothing left to initiate.
      if !viewModel.rainWalletSessionActive {
        if !viewModel.hasRainApiKey {
          RainWarningNote(text: "Login codes need the Rain API key above; the demo mints wallet auth tokens with it. The user ID is only needed for Withdraw and Auth pull.")
        }
        RainAsyncButton(
          title: viewModel.rainWalletOtpSent ? "Code sent" : "Send login code",
          enabled: viewModel.canSendRainWalletOtp
        ) {
          await viewModel.sendRainWalletOtp()
        }

        RainAsyncButton(
          title: "Sign in with passkey",
          kind: .secondary,
          enabled: !viewModel.isLoading
        ) {
          await viewModel.signInWithRainWalletPasskey()
        }
        RainAsyncButton(
          title: "Create wallet with passkey",
          kind: .secondary,
          enabled: !viewModel.isLoading
        ) {
          await viewModel.signUpWithRainWalletPasskey()
        }
      }

      if viewModel.rainWalletOtpSent {
        RainLabeledField(title: "Login code", placeholder: "123456", text: $viewModel.rainWalletOtpCode)
          .disabled(viewModel.rainWalletSessionActive || viewModel.rainWalletSecondCodeContact != nil)

        if let secondCodeContact = viewModel.rainWalletSecondCodeContact {
          RainLabeledField(
            title: "Second code (sent to \(secondCodeContact))", placeholder: "123456",
            text: $viewModel.rainWalletSecondCode
          )
          RainAsyncButton(title: "Verify second code & log in", enabled: viewModel.canVerifyRainWalletSecondCode) {
            await viewModel.verifyRainWalletSecondCode()
          }
          RainAsyncButton(title: "Resend second code", kind: .secondary, enabled: !viewModel.isLoading) {
            await viewModel.sendRainWalletSecondCode()
          }
        } else {
          RainAsyncButton(
            title: viewModel.rainWalletSessionActive ? "Session active" : "Verify & log in",
            enabled: viewModel.canVerifyRainWalletOtp
          ) {
            await viewModel.verifyRainWalletOtp()
          }
        }
      }

      if viewModel.rainWalletSessionActive {
        // Rain initializes automatically after the code verifies; this is only the retry for
        // when that init failed (e.g. missing Rain API credentials).
        if !viewModel.isInitialized {
          RainAsyncButton(
            title: "Initialize Rain with Rain Wallet",
            enabled: !viewModel.isLoading
          ) {
            await viewModel.initializeRainWithRainWallet()
          }
        }

        RainAsyncButton(
          title: "Add a passkey to this account",
          kind: .secondary,
          enabled: !viewModel.isLoading
        ) {
          await viewModel.addRainWalletPasskey()
        }

        // Attach the email/phone above as a VERIFIED login contact — the way a passkey-only
        // account gains a code-based login. Two steps, like sign-in.
        RainAsyncButton(
          title: viewModel.rainWalletAttachCodeSent
            ? "Verification code sent" : "Attach this contact to the account",
          kind: .secondary,
          enabled: viewModel.canSendRainWalletAttachCode
        ) {
          await viewModel.sendRainWalletAttachCode()
        }
        if viewModel.rainWalletAttachCodeSent {
          RainLabeledField(
            title: "Verification code", placeholder: "123456", text: $viewModel.rainWalletAttachCode
          )
          RainAsyncButton(title: "Confirm & attach", enabled: viewModel.canConfirmRainWalletAttach) {
            await viewModel.confirmRainWalletAttach()
          }
        }

        exportSection
      }
    }
  }

  // MARK: - Rain Wallet key export

  /// Tap-to-reveal export of the recovery phrase and per-chain private keys. The revealed value
  /// is only ever rendered here — never logged, persisted, or placed on the pasteboard.
  private var exportSection: some View {
    RainSectionCard(title: "Export keys") {
      RainAsyncButton(
        title: "Reveal recovery phrase",
        enabled: !viewModel.isLoading
      ) {
        await viewModel.exportRainWalletSecret(.recoveryPhrase)
      }
      RainAsyncButton(
        title: "Reveal Ethereum private key",
        enabled: !viewModel.isLoading
      ) {
        await viewModel.exportRainWalletSecret(.ethereumKey)
      }
      RainAsyncButton(
        title: "Reveal Solana private key",
        enabled: !viewModel.isLoading
      ) {
        await viewModel.exportRainWalletSecret(.solanaKey)
      }

      if let secret = viewModel.revealedSecret {
        VStack(alignment: .leading, spacing: RainMetrics.s1) {
          Text(secret.title)
            .font(.caption)
            .foregroundColor(.secondary)
          Text(secret.value)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: RainMetrics.s1) {
          RainAsyncButton(title: "Copy", kind: .secondary) {
            viewModel.copyRevealedSecret()
          }
          RainAsyncButton(title: "Hide", kind: .destructive) {
            viewModel.hideRevealedSecret()
          }
        }
      }
    }
  }

  // MARK: - Privy

  private var privySection: some View {
    RainSectionCard(title: "Privy configuration, email OTP") {
      RainLabeledField(title: "Privy app ID", placeholder: "your-privy-app-id", text: $viewModel.privyAppId)
        .disabled(viewModel.privyOtpSent || viewModel.privySessionActive)

      RainLabeledField(
        title: "Privy app client ID",
        placeholder: "your-privy-app-client-id",
        text: $viewModel.privyAppClientId
      )
      .disabled(viewModel.privyOtpSent || viewModel.privySessionActive)

      RainLabeledField(title: "Email", placeholder: "you@example.com", text: $viewModel.privyEmail)
        .disabled(viewModel.privyOtpSent || viewModel.privySessionActive)

      RainAsyncButton(
        title: viewModel.privyOtpSent ? "OTP sent" : "Init Privy & send OTP",
        enabled: viewModel.canSendPrivyOtp
      ) {
        await viewModel.sendPrivyOtp()
      }

      if viewModel.privyOtpSent && !viewModel.privySessionActive {
        RainLabeledField(title: "OTP code", placeholder: "123456", text: $viewModel.privyOtpCode)

        RainAsyncButton(
          title: "Verify & log in",
          enabled: viewModel.canVerifyPrivyOtp
        ) {
          await viewModel.verifyPrivyOtp()
        }
      }

      if viewModel.privySessionActive {
        RainAsyncButton(
          title: viewModel.isInitialized ? "Rain initialized" : "Initialize Rain with Privy",
          enabled: !viewModel.isLoading && !viewModel.isInitialized
        ) {
          await viewModel.initializeRainWithPrivy()
        }
      }
    }
  }

  // MARK: - Session state

  /// `sessionState`, `refreshSession()` and, for Portal, `updateSessionToken(_:)`.
  private func sessionSection(_ status: WalletSessionStatus) -> some View {
    RainSectionCard(title: "Wallet session") {
      HStack {
        RainStatusPill(text: status.label, active: status.health == .healthy)
        Spacer()
      }
      if let detail = status.detail {
        Text(detail)
          .font(RainFont.meta)
          .tracking(-0.12)
          .foregroundStyle(Color.rainTextMuted)
      }

      // What the resolved provider advertises (`RainClient.capabilities`), sorted so the readout
      // is stable across launches — testers compare it against the provider's documented set.
      if let client = sdkService.client {
        let names = client.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        Text("Capabilities: \(names.isEmpty ? "none" : names)")
          .font(RainFont.meta)
          .tracking(-0.12)
          .foregroundStyle(Color.rainTextMuted)
      }

      // Portal's refresh goes through onSessionTokenNeeded, which needs a replacement token.
      let canRefresh = !viewModel.isLoading
        && (viewModel.mode != .portal || viewModel.canUpdatePortalToken)
      RainAsyncButton(title: "Refresh session", kind: .secondary, enabled: canRefresh) {
        await viewModel.refreshSession()
      }

      if viewModel.mode == .portal {
        Text(
          "Replacement token: \"Update token\" installs it now (updateSessionToken); "
            + "refresh and any rejected call take it via onSessionTokenNeeded."
        )
        .font(RainFont.meta)
        .tracking(-0.12)
        .lineSpacing(4)
        .foregroundStyle(Color.rainTextMuted)

        RainLabeledField(
          title: "Replacement session token",
          placeholder: "Enter a freshly minted token",
          text: $viewModel.replacementPortalToken
        )

        RainAsyncButton(title: "Update token", kind: .secondary, enabled: viewModel.canUpdatePortalToken) {
          await viewModel.updatePortalSessionToken()
        }
      }
    }
  }

  // MARK: - Chain selector

  private var chainSelector: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s1) {
      RainSectionLabel(text: "Active wallet")

      Menu {
        ForEach(viewModel.availableChains) { chain in
          Button(chain.displayName) { sdkService.selectedChain = chain }
        }
      } label: {
        RainSelectorRow {
          Text(sdkService.selectedChain.displayName)
        }
      }
    }
    // Turnkey and Privy hold a Solana account; Portal is EVM-only.
    .onAppear { viewModel.normalizeSelectedChain() }
    .onChange(of: sdkService.selectedChain) { viewModel.normalizeSelectedChain() }
  }

  // MARK: - Feature grid

  private var featureGrid: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s1) {
      RainSectionLabel(text: "SDK features")

      LazyVGrid(
        columns: [GridItem(spacing: RainMetrics.s1), GridItem(spacing: RainMetrics.s1)],
        spacing: RainMetrics.s1
      ) {
        RainFeatureTile(icon: .walletQR, title: "Wallet & QR") { WalletInfoView() }
        RainFeatureTile(icon: .balances, title: "Balances") { BalancesView() }
        RainFeatureTile(icon: .sendTokens, title: "Send tokens") { SendTokensView() }
        RainFeatureTile(icon: .withdraw, title: "Withdraw") { CollateralWithdrawView() }
        RainFeatureTile(icon: .authPull, title: "Auth pull") { AuthPullView() }
        RainFeatureTile(icon: .history, title: "History") { TransactionHistoryView() }
      }
    }
  }
}

#Preview {
  HomeView()
}
