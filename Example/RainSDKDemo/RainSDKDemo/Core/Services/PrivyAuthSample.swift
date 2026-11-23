import Foundation
import PrivySDK

/// Sample-app glue that drives Privy's iOS SDK end-to-end (init, email OTP, embedded-wallet
/// provisioning) so the host app can hand a ready `Privy` singleton to
/// `RainSDKService.initializePrivy(privy:)`.
///
/// This file is NOT part of Rain SDK. It is reference code a host app would write itself — Rain SDK
/// intentionally does not own Privy auth. Copy / adapt for your own app.
@MainActor
final class PrivyAuthSample {
  static let shared = PrivyAuthSample()

  /// Privy must be a single instance for the app's lifetime; hold it here after init.
  private var instance: (any Privy)?

  /// Snapshot of the ids Privy was initialized with, to detect edits made afterwards.
  private var configuredWith: (appId: String, appClientId: String)?

  private init() {}

  /// Hand this to `RainSDKService.initializePrivy(privy:)` once auth is complete.
  var privy: any Privy {
    guard let instance else {
      fatalError("PrivyAuthSample.initialize(...) not called yet")
    }
    return instance
  }

  /// Initializes the Privy singleton. Idempotent; editing the ids afterwards throws, because
  /// Privy cannot be reconfigured without relaunching the app.
  func initialize(appId: String, appClientId: String) throws {
    let snapshot = (appId: appId, appClientId: appClientId)
    if let configuredWith {
      guard configuredWith == snapshot else {
        throw NSError(
          domain: "RainSDKDemo.Privy", code: -1,
          userInfo: [NSLocalizedDescriptionKey:
            "Privy is already configured with different values this session. Fully kill the app "
            + "and relaunch to change the App ID or App Client ID."])
      }
      return
    }
    configuredWith = snapshot
    SampleLog.d(
      "PrivyAuth",
      "init appId=\(SampleLog.maskToken(appId)) clientId=\(SampleLog.maskToken(appClientId))"
    )
    instance = PrivySdk.initialize(
      config: PrivyConfig(appId: appId, appClientId: appClientId)
    )
  }

  /// True when Privy restored an authenticated session from a prior run (skips the OTP round-trip).
  func hasActiveSession() async -> Bool {
    guard let instance else { return false }
    if case .authenticated = await instance.getAuthState() { return true }
    return false
  }

  /// Email of the user a restored session belongs to, or nil if it cannot be determined. Callers
  /// reusing a restored session MUST compare this against the email being logged in — a valid
  /// session for a *different* email must not be reused.
  func activeSessionEmail() async -> String? {
    guard await hasActiveSession(), let user = await instance?.getUser() else { return nil }
    for account in user.linkedAccounts {
      if case .email(let email) = account { return email.email }
    }
    return nil
  }

  /// Logs the Privy user out. Safe no-op if not authenticated.
  func logout() async {
    guard let user = await instance?.getUser() else { return }
    await user.logout()
  }

  /// Sends an email OTP. Throws on failure.
  func sendEmailOtp(email: String) async throws {
    SampleLog.d("PrivyAuth", "sendEmailOtp to=\(SampleLog.maskEmail(email))")
    try await privy.email.sendCode(to: email)
  }

  /// Verifies the OTP and creates a Privy session. Throws on failure.
  func verifyEmailOtp(code: String, email: String) async throws {
    SampleLog.d("PrivyAuth", "verifyEmailOtp email=\(SampleLog.maskEmail(email))")
    _ = try await privy.email.loginWithCode(code, sentTo: email)
    SampleLog.d("PrivyAuth", "session active")
  }

  /// Ensures the authenticated user has an embedded Ethereum wallet. Returns true when one was
  /// created.
  func ensureEthereumWallet() async throws -> Bool {
    let user = try await requireUser()
    guard user.embeddedEthereumWallets.isEmpty else {
      SampleLog.d("PrivyAuth", "ensureEthereumWallet — wallet already present")
      return false
    }
    let wallet = try await user.createEthereumWallet(allowAdditional: false)
    SampleLog.i("PrivyAuth", "created embedded wallet address=\(wallet.address)")
    return true
  }

  /// Ensures the authenticated user has an embedded Solana wallet (Rain's Solana operations use the
  /// first one). Returns true when one was created.
  func ensureSolanaWallet() async throws -> Bool {
    let user = try await requireUser()
    guard user.embeddedSolanaWallets.isEmpty else {
      SampleLog.d("PrivyAuth", "ensureSolanaWallet — wallet already present")
      return false
    }
    let wallet = try await user.createSolanaWallet(allowAdditional: false)
    SampleLog.i("PrivyAuth", "created embedded Solana wallet address=\(wallet.address)")
    return true
  }

  private func requireUser() async throws -> any PrivyUser {
    guard let user = await privy.getUser() else {
      throw NSError(
        domain: "RainSDKDemo.Privy", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Privy user not authenticated"])
    }
    return user
  }
}
