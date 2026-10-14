import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import TurnkeyCrypto
import TurnkeyHttp
import TurnkeyPasskeys
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

/// An in-flight OTP: the id and TEE-signed encryption bundle from `sendOtp`, needed to complete
/// the flow. Module-owned so test doubles can construct it.
internal struct OtpChallenge: Sendable, Equatable {
  let otpId: String
  let encryptionTargetBundle: String
}

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

  // MARK: Managed auth (email OTP via the auth proxy)

  /// Starts an OTP flow. Distinctly named so it cannot collide with the vendor's `initOtp`, and
  /// returns a module-owned value so mocks need not construct the vendor's result type.
  func sendOtp(contact: String, otpType: OtpType) async throws -> OtpChallenge

  /// The key the currently selected stored session lives under, if any.
  var selectedStoredSessionKey: String? { get }

  /// Completes the OTP flow (signup-or-login), storing the resulting session under `sessionKey`.
  /// On the signup path, `signupWalletAccounts` become the accounts of a single custom wallet
  /// created atomically with the sub-organization (one seed for every chain family); ignored on
  /// the login path. Distinctly named and fixed-arity so it cannot collide with the vendor's
  /// defaulted `completeOtp(...)`.
  func completeOtp(
    otpId: String,
    otpCode: String,
    otpEncryptionTargetBundle: String,
    contact: String,
    otpType: OtpType,
    sessionKey: String,
    signupWalletAccounts: [WalletAccountParams]
  ) async throws

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

  /// Signs a NEW user up with a passkey, creating the sub-organization and — atomically — one
  /// custom wallet carrying `signupWalletAccounts` (one seed for every chain family). Stores
  /// the session under the vendor's default key (see `loginWithTurnkeyPasskey`).
  func signUpWithTurnkeyPasskey(
    anchor: ASPresentationAnchor,
    signupWalletAccounts: [WalletAccountParams]
  ) async throws

  /// Registers an additional passkey authenticator on the authenticated user. No new account,
  /// no session change — afterwards the passkey signs into THIS account.
  func addPasskeyAuthenticator(anchor: ASPresentationAnchor, rpId: String) async throws

  // MARK: Contact verification (RainWallet)

  /// Verifies an OTP code WITHOUT logging in and returns the verification token proving the
  /// contact. Distinctly named so it cannot collide with the vendor's defaulted `verifyOtp(...)`.
  func verifyOtpToken(
    otpId: String,
    otpCode: String,
    otpEncryptionTargetBundle: String
  ) async throws -> String

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

  internal func sendOtp(contact: String, otpType: OtpType) async throws -> OtpChallenge {
    let result = try await initOtp(contact: contact, otpType: otpType)
    return OtpChallenge(otpId: result.otpId, encryptionTargetBundle: result.otpEncryptionTargetBundle)
  }

  internal var selectedStoredSessionKey: String? {
    selectedSessionKey
  }

  internal func completeOtp(
    otpId: String,
    otpCode: String,
    otpEncryptionTargetBundle: String,
    contact: String,
    otpType: OtpType,
    sessionKey: String,
    signupWalletAccounts: [WalletAccountParams]
  ) async throws {
    // The custom wallet is created atomically inside the signup call, closing the window where
    // the sub-organization exists but wallet provisioning failed. Login ignores these params.
    // CreateSubOrgParams has no public initializer at swift-sdk 4.0.0 — its Decodable witness is
    // the only way to construct one from outside the vendor module.
    var subOrgParams = try JSONDecoder().decode(CreateSubOrgParams.self, from: Data("{}".utf8))
    subOrgParams.customWallet = v1WalletParams(
      accounts: signupWalletAccounts,
      mnemonicLength: 12,
      walletName: "Wallet"
    )
    _ = try await completeOtp(
      otpId: otpId,
      otpCode: otpCode,
      otpEncryptionTargetBundle: otpEncryptionTargetBundle,
      contact: contact,
      otpType: otpType,
      createSubOrgParams: subOrgParams,
      // Server-side: kills every other login session the user has, on every device — a second
      // phone logging in logs the first out (documented on the managed TurnkeyConfig init;
      // Android passes the same value).
      invalidateExisting: true,
      sessionKey: sessionKey
    )
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

  internal func signUpWithTurnkeyPasskey(
    anchor: ASPresentationAnchor,
    signupWalletAccounts: [WalletAccountParams]
  ) async throws {
    // Same atomic provisioning as the OTP signup path: the custom wallet is created inside the
    // signup request. CreateSubOrgParams has no public initializer at swift-sdk 4.0.0 — its
    // Decodable witness is the only way to construct one from outside the vendor module.
    var subOrgParams = try JSONDecoder().decode(CreateSubOrgParams.self, from: Data("{}".utf8))
    subOrgParams.customWallet = v1WalletParams(
      accounts: signupWalletAccounts,
      mnemonicLength: 12,
      walletName: "Wallet"
    )
    _ = try await signUpWithPasskey(anchor: anchor, createSubOrgParams: subOrgParams)
  }

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

  internal func verifyOtpToken(
    otpId: String,
    otpCode: String,
    otpEncryptionTargetBundle: String
  ) async throws -> String {
    try await verifyOtp(
      otpId: otpId,
      otpCode: otpCode,
      otpEncryptionTargetBundle: otpEncryptionTargetBundle
    ).verificationToken
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
