import Testing
import AuthenticationServices
import Foundation
import TurnkeySwift
import TurnkeyTypes
@testable import RainCore
@_spi(RainWallet) @testable import RainTurnkey
@testable import RainWallet

@Suite("RainWallet")
struct RainWalletTests {
  /// Constructing a `RainProvider` configures the process-wide wallet backend and grabs the
  /// vendor singleton (which traps when unconfigured in a test host) — stub both seams so unit
  /// tests never touch real keychain/session machinery.
  init() {
    TurnkeyManagedConfigurator.configureImpl = { _, _ in }
    TurnkeyManagedConfigurator.sharedContext = { StubBackendContext() }
  }

  private static let backend = TurnkeyManagedAuthBackend(
    baseURL: URL(string: "https://api-dev.rain.xyz")!,
    tokenProvider: { _ in "wat-stub" }
  )

  /// A backing provider over the stub context and a canned rain-api.
  private static func backing(
    _ stub: StubBackendContext, rpId: String? = nil, api: StubRainApiAuthClient = StubRainApiAuthClient()
  ) -> TurnkeyProvider {
    TurnkeyProvider(
      config: TurnkeyConfig(organizationId: "org", authBackend: backend, rpId: rpId),
      context: stub,
      managedAuth: TurnkeyManagedAuthController(
        context: stub, configurationError: nil, rpId: rpId, api: api, tokenProvider: backend.tokenProvider,
        pendingPasskeySignups: StubPendingPasskeySignupStore()
      )
    )
  }

  // MARK: - State mapping

  @Test("session states map one-to-one onto the neutral enum")
  func testSessionStateMapping() {
    #expect(RainWalletSessionState(TurnkeySessionState.loading) == .loading)
    #expect(RainWalletSessionState(TurnkeySessionState.active(expiresAtEpochSeconds: 42)) == .active(expiresAtEpochSeconds: 42))
    #expect(RainWalletSessionState(TurnkeySessionState.expired) == .expired)
    #expect(RainWalletSessionState(TurnkeySessionState.unauthenticated) == .unauthenticated)
  }

  @Test("auth states map one-to-one onto the neutral enum")
  func testAuthStateMapping() {
    #expect(RainWalletAuthState(TurnkeyAuthState.loading) == .loading)
    #expect(RainWalletAuthState(TurnkeyAuthState.authenticated) == .authenticated)
    #expect(RainWalletAuthState(TurnkeyAuthState.unauthenticated) == .unauthenticated)
  }

  @Test("the session policy maps every field onto the backing policy")
  func testSessionPolicyMapping() {
    let policy = RainWalletSessionPolicy(
      refreshBufferSeconds: 30,
      autoRefresh: false,
      refreshExpirationSeconds: 1200,
      maxTransientRetries: 5,
      initialRetryDelay: 1,
      maxRetryDelay: 8
    )
    let backing = policy.backingPolicy
    #expect(backing.refreshBufferSeconds == 30)
    #expect(backing.autoRefresh == false)
    #expect(backing.refreshExpirationSeconds == 1200)
    #expect(backing.maxTransientRetries == 5)
    #expect(backing.initialRetryDelay == 1)
    #expect(backing.maxRetryDelay == 8)
  }

  // MARK: - Descriptor

  @Test("the descriptor advertises the .rain id and the backing capabilities")
  func testDescriptorIdentity() {
    let provider = RainProvider(
      RainWalletConfig()
    )
    #expect(provider.id == .rain)
    // Sponsorship is the product: on by default, and advertised as a capability.
    #expect(provider.capabilities == [.export, .multiChain, .gasSponsorship])
    #expect(RainProvider(RainWalletConfig(sponsorGas: false)).capabilities == [.export, .multiChain])
  }

  // MARK: - Configuration wiring

  @Test("the environment maps to Rain's hosts, production by default")
  func testEnvironmentWiring() {
    #expect(RainProvider(RainWalletConfig()).backing.managedAuthBackend?.baseURL.absoluteString == "https://api.rain.xyz")
    #expect(RainProvider(RainWalletConfig(environment: .sandbox)).backing.managedAuthBackend?.baseURL.absoluteString == "https://api-dev.rain.xyz")
    let staging = URL(string: "https://staging.example/api")!
    #expect(RainProvider(RainWalletConfig(environment: .custom(staging))).backing.managedAuthBackend?.baseURL == staging)
  }

  @Test("the token provider is handed to the backend with the contact translated, nil stays nil")
  func testTokenProviderWiring() async throws {
    let asked = Asked()
    let provider = RainProvider(RainWalletConfig(authTokenProvider: { contact in
      await asked.record(contact)
      return "wat-from-host"
    }))
    let backendProvider = try #require(provider.backing.managedAuthBackend?.tokenProvider)

    #expect(try await backendProvider(.email("user@example.com")) == "wat-from-host")
    #expect(try await backendProvider(.phone("+15551234567")) == "wat-from-host")
    #expect(try await backendProvider(nil) == "wat-from-host")
    #expect(await asked.contacts == [.email("user@example.com"), .phone("+15551234567"), nil])

    #expect(RainProvider(RainWalletConfig()).backing.managedAuthBackend?.tokenProvider == nil)
  }

  private actor Asked {
    var contacts: [RainWalletContact?] = []
    func record(_ contact: RainWalletContact?) { contacts.append(contact) }
  }

  // MARK: - Key export

  @Test("export methods delegate to the backend with the right account and encoding")
  func testExportDelegation() async throws {
    // Built around the public init: the process-wide configurator is one-shot, so a second
    // provider with fresh ids would carry a configurationError and fail every call. The internal
    // seams inject the stub directly instead.
    let stub = StubBackendContext()
    stub.wallets = [Self.dualAccountWallet()]
    let provider = RainProvider(backing: Self.backing(stub))

    let phrase = try await provider.exportRecoveryPhrase()
    let ethKey = try await provider.exportPrivateKey(.ethereum)
    let solKey = try await provider.exportPrivateKey(.solana)

    #expect(phrase == stub.stubbedMnemonic)
    #expect(ethKey == "0x" + stub.stubbedExportedKey) // Ethereum keys are 0x-prefixed
    #expect(solKey == stub.stubbedExportedKey)
    #expect(stub.exportMnemonicCalls == ["wallet-id"])
    #expect(stub.exportKeyCalls == [
      .init(address: "0xeth-address", encoding: .hexSecp256k1),
      .init(address: "sol-address", encoding: .solanaBase58),
    ])
  }

  /// `Wallet` has no public memberwise init — round-trip through its Codable conformance.
  private static func dualAccountWallet() -> Wallet {
    struct WalletFixture: Encodable {
      let walletId: String
      let walletName: String
      let createdAt: String
      let updatedAt: String
      let exported: Bool
      let imported: Bool
      let accounts: [WalletAccount]
    }
    func account(address: String, format: v1AddressFormat, curve: v1Curve, path: String) -> WalletAccount {
      WalletAccount(
        address: address,
        addressFormat: format,
        createdAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
        curve: curve,
        organizationId: "org-id",
        path: path,
        pathFormat: .path_format_bip32,
        publicKey: nil,
        updatedAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
        walletAccountId: "wallet-account-id-\(address)",
        walletDetails: nil,
        walletId: "wallet-id"
      )
    }
    let fixture = WalletFixture(
      walletId: "wallet-id", walletName: "wallet", createdAt: "0", updatedAt: "0",
      exported: false, imported: false,
      accounts: [
        account(
          address: "0xeth-address", format: .address_format_ethereum,
          curve: .curve_secp256k1, path: "m/44'/60'/0'/0/0"
        ),
        account(
          address: "sol-address", format: .address_format_solana,
          curve: .curve_ed25519, path: "m/44'/501'/0'/0'"
        ),
      ]
    )
    let data = try! JSONEncoder().encode(fixture)
    return try! JSONDecoder().decode(Wallet.self, from: data)
  }

  // MARK: - Passkeys + login contacts

  @MainActor
  @Test("close makes the provider inert: auth and export throw invalidConfig, state reads logged out")
  func testCloseIsTerminal() async throws {
    let stub = StubBackendContext()
    stub.session = Self.stubSession()
    stub.authState = .authenticated
    stub.wallets = [Self.dualAccountWallet()]
    let provider = RainProvider(backing: Self.backing(stub))
    #expect(provider.hasActiveSession())

    provider.close()
    provider.close() // idempotent

    #expect(!provider.hasActiveSession())
    #expect(provider.currentAuthState() == .unauthenticated)
    await #expect(throws: RainError.invalidConfig(details: "")) {
      try await provider.sendLoginCode(to: .email("a@b.c"))
    }
    await #expect(throws: RainError.invalidConfig(details: "")) {
      _ = try await provider.exportRecoveryPhrase()
    }
    await #expect(throws: RainError.invalidConfig(details: "")) { try await provider.logout() }
    #expect(stub.exportMnemonicCalls.isEmpty)
  }

  @MainActor
  @Test("login-contact, passkey and contact-attach methods delegate to the backend")
  func testAuthDelegation() async throws {
    let stub = StubBackendContext()
    stub.session = Self.stubSession()
    stub.authState = .authenticated
    let api = StubRainApiAuthClient()
    let provider = RainProvider(backing: Self.backing(stub, rpId: "passkeys.rain.xyz", api: api))
    let anchor = ASPresentationAnchor()

    try await provider.loginWithPasskey(anchor: anchor)
    try await provider.addPasskey(anchor: anchor)
    try await provider.sendContactVerificationCode(to: .phone("+15551234567"))
    try await provider.confirmContactVerification("123456")

    #expect(stub.loginWithPasskeyCallCount == 1)
    #expect(stub.addPasskeyCalls == ["passkeys.rain.xyz"])
    #expect(stub.setUserPhoneNumberCalls.map(\.0) == ["+15551234567"])
    // The verification token rain-api returned is what marks the contact verified.
    #expect(stub.setUserPhoneNumberCalls.first?.1 == api.verificationToken)
    #expect(api.tokens == ["wat-stub", "wat-stub"], "init + verify ride on the host-minted token")
  }

  /// `Session` has no public memberwise init — round-trip through its Codable conformance.
  private static func stubSession() -> Session {
    struct SessionFixture: Encodable {
      let exp: TimeInterval
      let publicKey: String
      let sessionType: String
      let userId: String
      let organizationId: String
      enum CodingKeys: String, CodingKey {
        case exp
        case publicKey = "public_key"
        case sessionType = "session_type"
        case userId = "user_id"
        case organizationId = "organization_id"
      }
    }
    let data = try! JSONEncoder().encode(SessionFixture(
      exp: Date().addingTimeInterval(3600).timeIntervalSince1970,
      publicKey: "pubkey",
      sessionType: "SESSION_TYPE_READ_WRITE",
      userId: "user-id",
      organizationId: "org-id"
    ))
    return try! JSONDecoder().decode(Session.self, from: data)
  }

  // MARK: - Registry exclusion

  @Test("build rejects registering the Rain wallet and Turnkey providers together")
  func testMutualExclusionGuard() {
    struct StubDescriptor: ProviderDescriptor {
      let id: ProviderId
      func create(context: ProviderContext) async throws -> any WalletProvider {
        throw RainError.walletUnavailable()
      }
    }
    #expect(throws: RainError.self) {
      _ = try RainSdk.builder()
        .rpcEndpoints([1: "https://mainnet.test"])
        .register(StubDescriptor(id: .rain))
        .register(StubDescriptor(id: .turnkey))
        .build()
    }
    // Either alone is fine.
    #expect(throws: Never.self) {
      _ = try RainSdk.builder()
        .rpcEndpoints([1: "https://mainnet.test"])
        .register(StubDescriptor(id: .rain))
        .build()
    }
  }
}
