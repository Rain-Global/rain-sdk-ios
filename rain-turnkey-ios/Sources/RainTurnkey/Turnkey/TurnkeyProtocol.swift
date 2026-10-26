import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import TurnkeyCrypto
import TurnkeyHttp
import TurnkeyPasskeys
import TurnkeyStamper
import TurnkeySwift
import TurnkeyTypes
@_spi(RainAdapter) import RainCore

internal protocol TurnkeyClientProtocol {
  func getWalletAddressBalances(
    _ input: TGetWalletAddressBalancesBody
  ) async throws -> TGetWalletAddressBalancesResponse

  func ethSendTransaction(
    _ input: TEthSendTransactionBody
  ) async throws -> TEthSendTransactionResponse

  func solSendTransaction(
    _ input: TSolSendTransactionBody
  ) async throws -> TSolSendTransactionResponse

  func getSendTransactionStatus(
    _ input: TGetSendTransactionStatusBody
  ) async throws -> TGetSendTransactionStatusResponse

  func getActivities(
    _ input: TGetActivitiesBody
  ) async throws -> TGetActivitiesResponse

  /// One activity by id — any status decodes (unlike the typed send responses, which only decode
  /// a COMPLETED activity). The send paths wait on an accepted-but-unfinished send through this.
  func getActivity(
    _ input: TGetActivityBody
  ) async throws -> TGetActivityResponse

  /// Account and gas-station nonces; sponsored sends fetch the gas-station nonce through this.
  func getNonces(
    _ input: TGetNoncesBody
  ) async throws -> TGetNoncesResponse
}

extension TurnkeyClient: TurnkeyClientProtocol {}

internal protocol TurnkeyContextProtocol: AnyObject {
  var wallets: [Wallet] { get }
  var session: Session? { get }
  var turnkeyClient: (any TurnkeyClientProtocol)? { get }
  var authState: AuthState { get }
  var authStatePublisher: AnyPublisher<AuthState, Never> { get }
  var sessionPublisher: AnyPublisher<Session?, Never> { get }

  func refreshWallets() async throws

  /// Refreshes the selected session; `nil` `expirationSeconds` uses Turnkey's default TTL.
  /// Distinctly named so it cannot collide with the vendor's defaulted `refreshSession(...)`.
  func refreshTurnkeySession(expirationSeconds: String?) async throws

  func signRawPayload(
    signWith: String,
    payload: String,
    encoding: PayloadEncoding,
    // Qualified: `import CryptoKit` (SolanaKeyEncoder) also exposes a `HashFunction` protocol.
    hashFunction: TurnkeySwift.HashFunction
  ) async throws -> SignRawPayloadResult

  // MARK: Managed auth — the device half of the one-time-code flow
  //
  // rain-api replaced the vendor's Auth Proxy for code send/verify, signup and login. What the
  // proxy flow did on-device inside `verifyOtp` / `loginWithOtp` the controller now does through
  // these seams, so the crypto stays mockable: a fresh key pair per attempt, the code encrypted
  // to it, the verification token (which carries that public key) turned into a signed client
  // message, and the session JWT rain-api returns stored under our per-attempt key.

  /// Generates a fresh P-256 key pair in secure storage and returns its hex public key. One per
  /// login attempt.
  func createOtpKeyPair() throws -> String

  /// Encrypts the typed code to the backend's target bundle, bound to `publicKey`.
  func encryptOtpCode(
    _ code: String,
    otpEncryptionTargetBundle: String,
    publicKey: String
  ) throws -> String

  /// The login message to sign, and the public key the verification token is bound to.
  func clientSignatureForLogin(verificationToken: String) throws -> (message: String, publicKey: String)

  /// The signup message to sign (contact only — rain-api provisions the wallet), and the key.
  func clientSignatureForSignup(
    verificationToken: String,
    email: String?,
    phoneNumber: String?
  ) throws -> (message: String, publicKey: String)

  /// Signs `message` with the stored private key behind `publicKey`, raw P-256 signature hex.
  func signClientMessage(_ message: String, publicKey: String) async throws -> String

  /// Stores a session JWT under `sessionKey` (the vendor's keychain registry; refuses an
  /// occupied key, auto-selects only when nothing was selected).
  func storeTurnkeySession(jwt: String, sessionKey: String) async throws

  /// The key the currently selected stored session lives under, if any.
  var selectedStoredSessionKey: String? { get }

  /// Derives additional accounts from an EXISTING wallet's seed (no new wallet, no new seed)
  /// and refreshes the wallet list.
  func addAccountsToTurnkeyWallet(
    walletId: String,
    accounts: [WalletAccountParams]
  ) async throws

  /// Activates the session stored under `sessionKey` (client, published session, auth state).
  func selectStoredSession(sessionKey: String) async throws

  /// Clears the session stored under `sessionKey`; `nil` clears the currently selected one
  /// (logout). Safe no-op when none exists.
  func clearStoredSession(sessionKey: String?)

  /// Creates a wallet with the given accounts on the authenticated account. Distinctly named so
  /// it cannot collide with the vendor's defaulted `createWallet(...)`.
  func createTurnkeyWallet(
    walletName: String,
    accounts: [WalletAccountParams],
    mnemonicLength: Int
  ) async throws

  // MARK: Passkeys (RainWallet)

  /// Signs an existing user in with a passkey assertion. At swift-sdk 4.0.0 the vendor stores
  /// the resulting session under ITS DEFAULT key — `sessionKey` arguments are accepted but
  /// ignored — see `TurnkeyManagedAuthController`'s passkey session handling.
  func loginWithTurnkeyPasskey(anchor: ASPresentationAnchor) async throws

  /// A fresh in-memory P256 pair for one passkey signup (see `TemporaryApiKey`).
  func makeTemporaryApiKey() -> TemporaryApiKey

  /// Runs the platform passkey-registration ceremony for `rpId` and returns what rain-api's
  /// `/signup/passkey` needs. No account, no session.
  func registerPasskey(anchor: ASPresentationAnchor, rpId: String, loginKey: TemporaryApiKey) async throws -> PasskeyRegistration

  /// `stamp_login` on `organizationId` stamped with the temporary key rain-api attached at
  /// signup — no biometric prompt — stored under `sessionKey`. Fails when the account carries no
  /// such key or its 60-second life has passed.
  func loginWithTemporaryKey(organizationId: String, key: TemporaryApiKey, sessionKey: String) async throws

  /// Registers an additional passkey authenticator on the authenticated user. No new account,
  /// no session change — afterwards the passkey signs into THIS account.
  func addPasskeyAuthenticator(anchor: ASPresentationAnchor, rpId: String) async throws

  // MARK: Contact verification (RainWallet)

  /// Sets the authenticated user's email; the verification token marks it VERIFIED, which is
  /// what lets the contact become a login method.
  func setUserEmail(_ email: String, verificationToken: String?) async throws

  /// Sets the authenticated user's phone number; the verification token marks it VERIFIED.
  func setUserPhoneNumber(_ phone: String, verificationToken: String?) async throws

  // MARK: Key export (RainWallet)

  /// Exports the wallet's mnemonic phrase, decrypted on-device by the vendor SDK. Distinctly
  /// named so it cannot collide with the vendor's defaulted `exportWallet(...)`.
  func exportWalletMnemonic(walletId: String) async throws -> String

  /// Exports one account's private key, decrypted on-device. `encoding` selects the output:
  /// 32-byte hex for secp256k1, plain Base58 of privkey‖pubkey for ed25519/Solana.
  func exportAccountPrivateKey(
    address: String,
    encoding: ExportedKeyEncoding
  ) async throws -> String
}

/// The device's login key for one passkey signup, hex; the public key compressed, as Turnkey
/// API keys take it. Persisted with the registration so a resend carries the same public key.
/// The private key is worth little on its own: it authorises a 60-second API key on an account
/// only the same passkey can otherwise open.
internal struct TemporaryApiKey: Sendable, Equatable, Codable {
  let publicKey: String
  let privateKey: String
}

/// A freshly registered passkey, in the shape rain-api's `/signup/passkey` validates (the
/// vendor's `v1Attestation` plus the challenge), together with the login key sent alongside it.
/// Module-owned so mocks need not build the vendor type.
internal struct PasskeyRegistration: Sendable, Equatable, Codable {
  let challenge: String
  let credentialId: String
  let clientDataJson: String
  let attestationObject: String
  /// Vendor `v1AuthenticatorTransport` raw values.
  let transports: [String]
  let loginKey: TemporaryApiKey

  var apiAttestation: RainApiPasskeyAttestation {
    RainApiPasskeyAttestation(
      challenge: challenge,
      attestation: .init(
        credentialId: credentialId,
        clientDataJson: clientDataJson,
        attestationObject: attestationObject,
        transports: transports
      ),
      publicKey: loginKey.publicKey
    )
  }
}

/// Output encoding for a single exported private key. Module-owned so the protocol (and mocks)
/// don't depend on TurnkeyCrypto's `KeyFormat`.
internal enum ExportedKeyEncoding: Sendable, Equatable {
  /// Raw 32-byte key as hex (no 0x prefix) — Ethereum/secp256k1.
  case hexSecp256k1
  /// Plain Base58 of privkey‖pubkey (64 bytes, no checksum) — the format Solana wallets import.
  case solanaBase58
}

extension TurnkeyContext: TurnkeyContextProtocol {
  internal var turnkeyClient: (any TurnkeyClientProtocol)? {
    client
  }

  internal var authStatePublisher: AnyPublisher<AuthState, Never> {
    $authState.eraseToAnyPublisher()
  }

  internal var sessionPublisher: AnyPublisher<Session?, Never> {
    $session.eraseToAnyPublisher()
  }

  internal func refreshTurnkeySession(expirationSeconds: String?) async throws {
    if let expirationSeconds {
      try await refreshSession(expirationSeconds: expirationSeconds)
    } else {
      try await refreshSession()
    }
  }

  internal var selectedStoredSessionKey: String? {
    selectedSessionKey
  }

  internal func createOtpKeyPair() throws -> String {
    try createKeyPair()
  }

  internal func encryptOtpCode(
    _ code: String,
    otpEncryptionTargetBundle: String,
    publicKey: String
  ) throws -> String {
    try TurnkeyCrypto.encryptOtpCodeToBundle(
      otpCode: code,
      otpEncryptionTargetBundle: otpEncryptionTargetBundle,
      publicKey: publicKey
    )
  }

  internal func clientSignatureForLogin(verificationToken: String) throws -> (message: String, publicKey: String) {
    let (message, publicKey) = try ClientSignature.forLogin(verificationToken: verificationToken)
    return (message, publicKey)
  }

  internal func clientSignatureForSignup(
    verificationToken: String,
    email: String?,
    phoneNumber: String?
  ) throws -> (message: String, publicKey: String) {
    let (message, publicKey) = try ClientSignature.forSignup(
      verificationToken: verificationToken,
      email: email,
      phoneNumber: phoneNumber
    )
    return (message, publicKey)
  }

  internal func signClientMessage(_ message: String, publicKey: String) async throws -> String {
    // The stamper resolves the private key from secure storage by its public key — the one
    // `createOtpKeyPair` made for this attempt and the verification token is bound to.
    let stamper = try Stamper(apiPublicKey: publicKey)
    return try await stamper.sign(payload: message, format: .raw)
  }

  internal func storeTurnkeySession(jwt: String, sessionKey: String) async throws {
    try await storeSession(jwt: jwt, sessionKey: sessionKey)
  }

  internal func addAccountsToTurnkeyWallet(
    walletId: String,
    accounts: [WalletAccountParams]
  ) async throws {
    // The vendor exposes create_wallet_accounts only on the raw client; in production the
    // context's client is always the concrete TurnkeyClient.
    guard let client = turnkeyClient as? TurnkeyClient, let session else {
      throw TurnkeySwiftError.invalidSession
    }
    _ = try await client.createWalletAccounts(TCreateWalletAccountsBody(
      organizationId: session.organizationId,
      accounts: accounts,
      walletId: walletId
    ))
    try await refreshWallets()
  }

  internal func selectStoredSession(sessionKey: String) async throws {
    _ = try await setActiveSession(sessionKey: sessionKey)
  }

  internal func clearStoredSession(sessionKey: String?) {
    // The vendor resolves `nil` to the currently selected session.
    clearSession(for: sessionKey)
  }

  internal func createTurnkeyWallet(
    walletName: String,
    accounts: [WalletAccountParams],
    mnemonicLength: Int
  ) async throws {
    _ = try await createWallet(
      walletName: walletName,
      accounts: accounts,
      mnemonicLength: Int32(mnemonicLength)
    )
  }

  internal func loginWithTurnkeyPasskey(anchor: ASPresentationAnchor) async throws {
    _ = try await loginWithPasskey(anchor: anchor)
  }

  internal func makeTemporaryApiKey() -> TemporaryApiKey {
    let (_, publicKeyCompressed, privateKey) = TurnkeyCrypto.generateP256KeyPair()
    return TemporaryApiKey(publicKey: publicKeyCompressed, privateKey: privateKey)
  }

  internal func registerPasskey(
    anchor: ASPresentationAnchor,
    rpId: String,
    loginKey: TemporaryApiKey
  ) async throws -> PasskeyRegistration {
    let passkeyName = "passkey-\(Int(Date().timeIntervalSince1970))"
    let passkey = try await createPasskey(
      user: PasskeyUser(id: UUID().uuidString, name: passkeyName, displayName: passkeyName),
      rp: RelyingParty(id: rpId, name: ""),
      presentationAnchor: anchor
    )
    return PasskeyRegistration(
      challenge: passkey.challenge,
      credentialId: passkey.attestation.credentialId,
      clientDataJson: passkey.attestation.clientDataJson,
      attestationObject: passkey.attestation.attestationObject,
      transports: passkey.attestation.transports.map(\.rawValue),
      loginKey: loginKey
    )
  }

  internal func loginWithTemporaryKey(
    organizationId: String,
    key: TemporaryApiKey,
    sessionKey: String
  ) async throws {
    // Mirrors the vendor's own proxy-era `signUpWithPasskey` (swift-sdk 4.0.0,
    // TurnkeyContext+Passkey.swift). `baseUrl` defaults to the host the context uses. 900 s
    // matches the sessions rain-api's `/login` issues.
    let temporaryClient = TurnkeyClient(
      apiPrivateKey: key.privateKey,
      apiPublicKey: key.publicKey,
      organizationId: organizationId
    )
    let sessionPublicKey = try createKeyPair()
    let login = try await temporaryClient.stampLogin(TStampLoginBody(
      organizationId: organizationId,
      expirationSeconds: Self.signupSessionExpirationSeconds,
      invalidateExisting: false,
      publicKey: sessionPublicKey
    ))
    try await storeSession(jwt: login.session, sessionKey: sessionKey)
  }

  private static let signupSessionExpirationSeconds = "900"

  internal func addPasskeyAuthenticator(anchor: ASPresentationAnchor, rpId: String) async throws {
    // The vendor has no high-level "add a passkey to the current account" at 4.0.0; composed
    // from its public pieces: the platform ceremony, then create_authenticators on the raw
    // client (see addAccountsToTurnkeyWallet for the same cast).
    guard let client = turnkeyClient as? TurnkeyClient, let session, authState == .authenticated
    else {
      throw TurnkeySwiftError.invalidSession
    }
    let passkeyName = "passkey-\(Int(Date().timeIntervalSince1970))"
    let passkey = try await createPasskey(
      user: PasskeyUser(id: UUID().uuidString, name: passkeyName, displayName: passkeyName),
      rp: RelyingParty(id: rpId, name: ""),
      presentationAnchor: anchor
    )
    _ = try await client.createAuthenticators(TCreateAuthenticatorsBody(
      organizationId: session.organizationId,
      authenticators: [v1AuthenticatorParamsV2(
        attestation: passkey.attestation,
        authenticatorName: passkeyName,
        challenge: passkey.challenge
      )],
      userId: session.userId
    ))
  }

  internal func setUserEmail(_ email: String, verificationToken: String?) async throws {
    try await updateUserEmail(email: email, verificationToken: verificationToken)
  }

  internal func setUserPhoneNumber(_ phone: String, verificationToken: String?) async throws {
    try await updateUserPhoneNumber(phone: phone, verificationToken: verificationToken)
  }

  internal func exportWalletMnemonic(walletId: String) async throws -> String {
    // The vendor call generates an ephemeral P256 pair, has the enclave encrypt the seed to it,
    // and decrypts locally — the plaintext never leaves the device unencrypted.
    try await exportWallet(walletId: walletId)
  }

  internal func exportAccountPrivateKey(
    address: String,
    encoding: ExportedKeyEncoding
  ) async throws -> String {
    // No high-level per-account export at swift-sdk 4.0.0; composed from the vendor's public
    // pieces, mirroring its own exportWallet implementation. The raw client is needed for
    // export_wallet_account (see addAccountsToTurnkeyWallet for the same cast).
    guard let client = turnkeyClient as? TurnkeyClient, let session, authState == .authenticated
    else {
      throw TurnkeySwiftError.invalidSession
    }
    // Ephemeral: the enclave encrypts the key material to this pair; both halves stay in this
    // function's scope and die with it.
    let (targetPublicKey, _, embeddedPrivateKey) = TurnkeyCrypto.generateP256KeyPair()
    do {
      let response = try await client.exportWalletAccount(TExportWalletAccountBody(
        organizationId: session.organizationId,
        address: address,
        targetPublicKey: targetPublicKey
      ))
      // Always decrypt to the raw key as hex (`.other`). The vendor's `.solana` format is
      // Base58Check — a 4-byte checksum Solana wallets like Phantom reject — so the standard
      // plain-Base58 keypair is built below instead.
      let hex = try TurnkeyCrypto.decryptExportBundle(
        exportBundle: response.exportBundle,
        organizationId: session.organizationId,
        embeddedPrivateKey: embeddedPrivateKey,
        keyFormat: .other,
        returnMnemonic: false
      )
      switch encoding {
      case .hexSecp256k1:
        return hex
      case .solanaBase58:
        return try SolanaKeyEncoder.keypairBase58(privateKeyHex: hex)
      }
    } catch {
      throw TurnkeySwiftError.failedToExportWallet(underlying: error)
    }
  }
}

/// Builds the standard Solana wallet-import string from a raw ed25519 private key.
internal enum SolanaKeyEncoder {
  /// Plain Base58 of the 64-byte ed25519 keypair (privkey‖pubkey) — the import format Solana
  /// wallets (Phantom, Solflare) expect. No checksum.
  internal static func keypairBase58(privateKeyHex: String) throws -> String {
    guard let privateKeyBytes = bytes(fromHex: privateKeyHex), privateKeyBytes.count == 32 else {
      throw TurnkeySwiftError.invalidResponse
    }
    let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(privateKeyBytes))
      .publicKey.rawRepresentation
    return Base58.encode(privateKeyBytes + [UInt8](publicKey))
  }

  private static func bytes(fromHex hex: String) -> [UInt8]? {
    let cleaned = hex.strippingHexPrefix
    guard cleaned.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
      let next = cleaned.index(index, offsetBy: 2)
      guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }
}
