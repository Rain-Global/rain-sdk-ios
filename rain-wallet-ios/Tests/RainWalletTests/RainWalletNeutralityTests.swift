import Testing
import AuthenticationServices
import Foundation
import Combine
import RainWallet // deliberately the ONLY SDK import — see below

/// Compiles against a bare `import RainWallet`, proving the module's public surface is complete
/// and wallet-neutral: everything an integrator writes (config, descriptor, auth, session, the
/// re-exported core) is expressible without importing — or ever seeing — any other module.
/// If a vendor type leaked into a public signature, this file would stop compiling.
///
/// The full integration flow lives in a deliberately UNEXECUTED closure: compiling it is the
/// guarantee; running it would touch the process-wide wallet backend, which this file — by
/// design — has no test seams to stub.
@Suite("RainWallet Neutrality")
struct RainWalletNeutralityTests {
  /// Never called. Type-checks the complete integration surface with module-owned names only.
  @MainActor
  private static func integrationSurface() async throws {
    let anchor = ASPresentationAnchor()
    let tokenProvider: RainWalletAuthTokenProvider = { (contact: RainWalletContact?) in "wat_…" }
    let provider = RainProvider(
      RainWalletConfig(
        environment: .sandbox,
        authTokenProvider: tokenProvider,
        passkeyDomain: "passkeys.example.com",
        sessionPolicy: RainWalletSessionPolicy(autoRefresh: true),
        onSessionExpired: {}
      )
    )
    let _: RainWalletEnvironment = .custom(URL(string: "https://staging.example")!)
    let _: RainProvider = RainProvider() // zero-config: passkey login only, production

    // Auth + session surface, fully typed with module-owned names.
    let _: RainWalletAuthState = provider.currentAuthState()
    let _: AnyPublisher<RainWalletAuthState, Never> = provider.authState
    await provider.awaitSessionRestore(timeout: 1)
    if !provider.hasActiveSession() {
      try await provider.sendLoginCode(to: .email("user@example.com"))
      try await provider.sendLoginCode(to: RainWalletContact.phone("+15551234567"))
      try await provider.confirmLoginCode("123456")
      try await provider.loginWithPasskey(anchor: anchor)
      try await provider.signUpWithPasskey(anchor: anchor)
    }
    try await provider.addPasskey(anchor: anchor)
    try await provider.sendContactVerificationCode(to: .phone("+15551234567"))
    try await provider.confirmContactVerification("123456")
    let _: AnyPublisher<RainWalletSessionState, Never> = provider.sessionState
    let _: RainWalletSessionState = provider.currentSessionState()
    try await provider.refreshSession()

    // Key export, fully typed with module-owned names.
    let _: String = try await provider.exportRecoveryPhrase()
    let _: String = try await provider.exportPrivateKey(.ethereum)
    let _: String = try await provider.exportPrivateKey(RainWalletKeyAccount.solana)
    try await provider.logout()
    provider.close()

    // The re-exported core surface resolves through this one import.
    let rain: RainSdk = try RainSdk.builder()
      .rpcEndpoints([1: "https://mainnet.test"])
      .register(provider)
      .build()
    let client: any RainClient = try await rain.provider(.rain)
    _ = try await client.getWalletAddress()
  }

  @Test("the neutral integration surface compiles with a bare import RainWallet")
  func testPublicSurface() {
    // The compile of `integrationSurface` is the assertion. Runtime checks stay to the
    // side-effect-free corners of the surface.
    _ = Self.integrationSurface

    let expired: RainWalletSessionState = .expired
    #expect(expired != .unauthenticated)
    #expect(RainWalletAuthState.authenticated == .authenticated)
    let policy = RainWalletSessionPolicy()
    #expect(policy.autoRefresh)
    let error: RainError = .tokenExpired // re-exported core type
    #expect(error == .tokenExpired)
    #expect(ProviderId.rain.rawValue == "rain")
  }
}
