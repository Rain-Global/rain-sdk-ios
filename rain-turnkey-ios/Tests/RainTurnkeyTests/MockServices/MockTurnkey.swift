import AuthenticationServices
import Combine
import Foundation
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey
import TurnkeyHttp
import TurnkeySwift
import TurnkeyTypes

final class MockTurnkeyClient: TurnkeyClientProtocol {
  struct StatusFixture {
    var txHash: String?
    var txStatus: String = "TX_STATUS_BROADCASTED"
    var txError: String?
    var errorMessage: String?
    var solanaSignature: String?
    /// Decoded EVM revert chain on `error.revertChain` (a contract rejecting the transaction).
    var revertChain: [v1RevertChainEntry]?
    /// Decoded Solana failure details on `error.solana` (the program rejecting the transaction).
    var solanaFailure: v1SolanaFailureDetails?

    static func broadcasted(hash: String) -> StatusFixture {
      StatusFixture(txHash: hash, txStatus: "TX_STATUS_BROADCASTED")
    }

    static func pending() -> StatusFixture {
      StatusFixture(txHash: nil, txStatus: "TX_STATUS_PENDING")
    }

    static func failed(message: String = "broadcast failed") -> StatusFixture {
      StatusFixture(txHash: nil, txStatus: "TX_STATUS_FAILED", txError: message)
    }

    /// Failed with Turnkey's decoded on-chain revert attached — what a sponsored send (no
    /// client-side dry run) reports when the contract rejects it.
    static func revertedOnChain(message: String = "execution reverted") -> StatusFixture {
      StatusFixture(
        txHash: nil, txStatus: "TX_STATUS_FAILED", errorMessage: message,
        revertChain: [v1RevertChainEntry(displayMessage: message, errorType: "native")]
      )
    }

    /// Failed with Solana program failure details attached.
    static func solanaRevertedOnChain(message: String = "custom program error: 0x1") -> StatusFixture {
      StatusFixture(
        txHash: nil, txStatus: "TX_STATUS_FAILED", errorMessage: message,
        solanaFailure: v1SolanaFailureDetails(rpcMessage: message)
      )
    }

    /// Solana submission Included on-chain, carrying the signature in the status response.
    static func solanaIncluded(signature: String) -> StatusFixture {
      StatusFixture(txStatus: "TX_STATUS_INCLUDED", solanaSignature: signature)
    }

    /// Solana submission Included on-chain but with no signature in the status response,
    /// forcing the adapter's recover-from-chain fallback.
    static func solanaIncludedWithoutSignature() -> StatusFixture {
      StatusFixture(txStatus: "TX_STATUS_INCLUDED")
    }
  }

  var mockBalances: [v1AssetBalance] = []
  var mockSendTransactionStatusId = "send-status-id"
  var mockSolSendTransactionStatusId = "sol-send-status-id"
  var mockTransactionHash = "0x" + String(repeating: "d", count: 64)
  var mockActivities: [v1Activity] = []

  /// Error to throw from `ethSendTransaction`. When set, the mock fails before producing a response.
  var ethSendTransactionError: Error?
  /// Error to throw from `solSendTransaction`. When set, the mock fails before producing a response.
  var solSendTransactionError: Error?
  /// Error to throw from `getWalletAddressBalances`. When set, the mock fails before producing a response.
  var walletAddressBalancesError: Error?
  /// Error to throw from `getActivities`. When set, the mock fails before producing a response.
  var getActivitiesError: Error?
  /// Error to throw from `getSendTransactionStatus`. When set, the mock fails before producing a response.
  var sendTransactionStatusError: Error?

  /// Optional queue of status responses returned sequentially by `getSendTransactionStatus`.
  /// When non-empty, each call consumes the next entry; the final entry is reused for subsequent calls.
  /// When empty (default), a single BROADCASTED status containing `mockTransactionHash` is returned.
  var sendTransactionStatusQueue: [StatusFixture] = []

  var walletAddressBalanceCalls: [TGetWalletAddressBalancesBody] = []
  var ethSendTransactionCalls: [TEthSendTransactionBody] = []
  var solSendTransactionCalls: [TSolSendTransactionBody] = []
  var sendTransactionStatusCalls: [TGetSendTransactionStatusBody] = []
  var getActivitiesCalls: [TGetActivitiesBody] = []

  func getWalletAddressBalances(
    _ input: TGetWalletAddressBalancesBody
  ) async throws -> TGetWalletAddressBalancesResponse {
    walletAddressBalanceCalls.append(input)

    if let walletAddressBalancesError {
      throw walletAddressBalancesError
    }

    return MockTurnkey.decode(
      WalletAddressBalancesResponseFixture(balances: mockBalances),
      as: TGetWalletAddressBalancesResponse.self
    )
  }

  func ethSendTransaction(
    _ input: TEthSendTransactionBody
  ) async throws -> TEthSendTransactionResponse {
    ethSendTransactionCalls.append(input)

    if let ethSendTransactionError {
      throw ethSendTransactionError
    }

    return MockTurnkey.decode(
      EthSendTransactionResponseFixture(
        activity: MockTurnkey.makeActivity(
          id: UUID().uuidString,
          from: input.from,
          to: input.to,
          caip2: input.caip2,
          value: input.value,
          data: input.data,
          sendTransactionStatusId: mockSendTransactionStatusId
        ),
        sendTransactionStatusId: mockSendTransactionStatusId
      ),
      as: TEthSendTransactionResponse.self
    )
  }

  func solSendTransaction(
    _ input: TSolSendTransactionBody
  ) async throws -> TSolSendTransactionResponse {
    solSendTransactionCalls.append(input)

    if let solSendTransactionError {
      throw solSendTransactionError
    }

    return MockTurnkey.decode(
      SolSendTransactionResponseFixture(
        activity: MockTurnkey.makeSolanaActivity(
          id: UUID().uuidString,
          signWith: input.signWith,
          caip2: input.caip2,
          unsignedTransaction: input.unsignedTransaction,
          sendTransactionStatusId: mockSolSendTransactionStatusId
        ),
        sendTransactionStatusId: mockSolSendTransactionStatusId
      ),
      as: TSolSendTransactionResponse.self
    )
  }

  func getSendTransactionStatus(
    _ input: TGetSendTransactionStatusBody
  ) async throws -> TGetSendTransactionStatusResponse {
    sendTransactionStatusCalls.append(input)

    if let sendTransactionStatusError {
      throw sendTransactionStatusError
    }

    let fixture: StatusFixture
    if sendTransactionStatusQueue.isEmpty {
      fixture = StatusFixture.broadcasted(hash: mockTransactionHash)
    } else if sendTransactionStatusQueue.count == 1 {
      fixture = sendTransactionStatusQueue[0]
    } else {
      fixture = sendTransactionStatusQueue.removeFirst()
    }

    return Self.statusResponse(fixture)
  }

  /// The vendor status response a fixture stands for.
  static func statusResponse(_ fixture: StatusFixture) -> TGetSendTransactionStatusResponse {
    MockTurnkey.decode(
      SendTransactionStatusResponseFixture(
        error: (fixture.errorMessage != nil || fixture.revertChain != nil || fixture.solanaFailure != nil)
          ? v1TxError(
            message: fixture.errorMessage, revertChain: fixture.revertChain, solana: fixture.solanaFailure
          )
          : nil,
        eth: fixture.txHash.map { v1EthSendTransactionStatus(txHash: $0) },
        solana: fixture.solanaSignature.map { v1SolanaSendTransactionStatus(signature: $0) },
        txError: fixture.txError,
        txStatus: fixture.txStatus
      ),
      as: TGetSendTransactionStatusResponse.self
    )
  }

  func getActivities(
    _ input: TGetActivitiesBody
  ) async throws -> TGetActivitiesResponse {
    getActivitiesCalls.append(input)

    if let getActivitiesError {
      throw getActivitiesError
    }

    return MockTurnkey.decode(
      ActivitiesResponseFixture(activities: mockActivities),
      as: TGetActivitiesResponse.self
    )
  }

  // MARK: Activity by id (accepted-but-unfinished sends)

  /// Sequential answers to `getActivity`; the last entry is reused once consumed. Empty: the
  /// activity is looked up in `mockActivities` by id, and a miss throws.
  var activityByIdQueue: [v1Activity] = []
  var getActivityCalls: [TGetActivityBody] = []
  var getActivityError: Error?

  func getActivity(
    _ input: TGetActivityBody
  ) async throws -> TGetActivityResponse {
    getActivityCalls.append(input)
    if let getActivityError { throw getActivityError }
    let activity: v1Activity
    if activityByIdQueue.isEmpty {
      guard let found = mockActivities.first(where: { $0.id == input.activityId }) else {
        throw TurnkeyRequestError.apiError(statusCode: 404, payload: nil)
      }
      activity = found
    } else if activityByIdQueue.count == 1 {
      activity = activityByIdQueue[0]
    } else {
      activity = activityByIdQueue.removeFirst()
    }
    return MockTurnkey.decode(ActivityResponseFixture(activity: activity), as: TGetActivityResponse.self)
  }

  /// The error the real vendor client throws for a send whose activity is not COMPLETED after
  /// its poll (swift-sdk 4.0.0): it decodes the raw `{activity}` answer into the typed response,
  /// whose `sendTransactionStatusId` is non-optional, and `JSONDecoder` fails. Built the same
  /// way so the adapter is exercised against the genuine error shape.
  static func activityNotCompletedError(_ activity: v1Activity, kind: TurnkeySendKind) -> Error {
    let data = try! JSONEncoder().encode(ActivityResponseFixture(activity: activity))
    do {
      switch kind {
      case .evm: _ = try JSONDecoder().decode(TEthSendTransactionResponse.self, from: data)
      case .solana: _ = try JSONDecoder().decode(TSolSendTransactionResponse.self, from: data)
      }
      fatalError("a non-completed activity must not decode as a send response")
    } catch {
      return error
    }
  }

  // MARK: Nonces (sponsored sends)

  /// The gas-station nonce a sponsored send fetches; `nil` mirrors Turnkey returning none.
  var mockGasStationNonce: String? = "7"
  var getNoncesCalls: [TGetNoncesBody] = []
  var getNoncesError: Error?

  func getNonces(
    _ input: TGetNoncesBody
  ) async throws -> TGetNoncesResponse {
    getNoncesCalls.append(input)
    if let getNoncesError { throw getNoncesError }
    struct NoncesFixture: Encodable {
      let gasStationNonce: String?
      let nonce: String?
    }
    return MockTurnkey.decode(
      NoncesFixture(gasStationNonce: mockGasStationNonce, nonce: nil),
      as: TGetNoncesResponse.self
    )
  }
}

final class MockTurnkey: TurnkeyContextProtocol, @unchecked Sendable {
  struct SignRawPayloadCall: Sendable {
    let signWith: String
    let payload: String
    let encoding: PayloadEncoding
    let hashFunction: HashFunction
  }

  static let defaultWalletAddress = "0x1234567890123456789012345678901234567890"

  var wallets: [Wallet] = []
  var turnkeyClient: (any TurnkeyClientProtocol)?
  var refreshWalletsCallCount = 0
  var signRawPayloadCalls: [SignRawPayloadCall] = []

  // Backed by subjects so coordinator/state tests can observe assignments like production
  // code observes the Turnkey singleton's @Published state.
  private let sessionSubject: CurrentValueSubject<Session?, Never>
  var session: Session? {
    get { sessionSubject.value }
    set { sessionSubject.send(newValue) }
  }

  var sessionPublisher: AnyPublisher<Session?, Never> { sessionSubject.eraseToAnyPublisher() }

  let authStateSubject: CurrentValueSubject<AuthState, Never>
  var authState: AuthState {
    get { authStateSubject.value }
    set { authStateSubject.send(newValue) }
  }

  var authStatePublisher: AnyPublisher<AuthState, Never> { authStateSubject.eraseToAnyPublisher() }

  /// Runs inside `refreshWallets` (e.g. to populate `wallets` after a simulated delay).
  var onRefreshWallets: (() async throws -> Void)?

  var refreshSessionCallCount = 0
  /// TTLs passed to `refreshTurnkeySession`, `nil` meaning "Turnkey default".
  var refreshSessionCalls: [String?] = []
  /// Error to throw from `refreshTurnkeySession`.
  var refreshSessionError: Error?
  /// Runs after a recorded `refreshTurnkeySession` call — install the refreshed session here.
  var onRefreshSession: (() -> Void)?

  var mockSignature = SignRawPayloadResult(
    r: String(repeating: "1", count: 64),
    s: String(repeating: "2", count: 64),
    v: "28"
  )

  /// Error to throw from `signRawPayload`. When set, the mock fails before producing a signature.
  var signRawPayloadError: Error?

  init(
    wallets: [Wallet] = [MockTurnkey.defaultWallet()],
    session: Session? = MockTurnkey.defaultSession(),
    client: (any TurnkeyClientProtocol)? = MockTurnkeyClient()
  ) {
    self.wallets = wallets
    self.sessionSubject = CurrentValueSubject(session)
    self.authStateSubject = CurrentValueSubject(
      session != nil ? .authenticated : .unAuthenticated
    )
    self.turnkeyClient = client
    // A live session is always selected under some key (the vendor restores it that way).
    self.selectedStoredSessionKey = session != nil ? "previous-session-key" : nil
    if session != nil { self.storedSessionKeys = ["previous-session-key"] }
  }

  func refreshWallets() async throws {
    refreshWalletsCallCount += 1
    try await onRefreshWallets?()
  }

  func refreshTurnkeySession(expirationSeconds: String?) async throws {
    refreshSessionCallCount += 1
    refreshSessionCalls.append(expirationSeconds)
    if let refreshSessionError {
      throw refreshSessionError
    }
    onRefreshSession?()
  }

  // MARK: Managed auth seams — the device half of the code flow

  struct CreateWalletCall { let walletName: String; let accounts: [WalletAccountParams]; let mnemonicLength: Int }

  /// Public keys handed out by `createOtpKeyPair`, in order ("otp-key-1", "otp-key-2", …).
  var createdOtpKeys: [String] = []
  var createOtpKeyPairError: Error?

  struct EncryptOtpCall: Equatable { let code: String; let otpEncryptionTargetBundle: String; let publicKey: String }
  var encryptOtpCalls: [EncryptOtpCall] = []
  var encryptOtpError: Error?

  struct SignupMessageCall: Equatable { let verificationToken: String; let email: String?; let phoneNumber: String? }
  var loginMessageCalls: [String] = []
  var signupMessageCalls: [SignupMessageCall] = []
  /// The key the fake verification token is "bound to" — what `clientSignatureFor…` return.
  var stubbedClientSignatureKey = "otp-key-1"

  struct SignCall: Equatable { let message: String; let publicKey: String }
  var signClientMessageCalls: [SignCall] = []
  var signClientMessageError: Error?

  struct StoreSessionCall: Equatable { let jwt: String; let sessionKey: String }
  var storeSessionCalls: [StoreSessionCall] = []
  var storeSessionError: Error?
  /// Runs after a successful `storeTurnkeySession` — install the new session / authState here.
  var onStoreSession: (() -> Void)?

  func createOtpKeyPair() throws -> String {
    if let createOtpKeyPairError { throw createOtpKeyPairError }
    let key = "otp-key-\(createdOtpKeys.count + 1)"
    createdOtpKeys.append(key)
    return key
  }

  func encryptOtpCode(_ code: String, otpEncryptionTargetBundle: String, publicKey: String) throws -> String {
    encryptOtpCalls.append(.init(code: code, otpEncryptionTargetBundle: otpEncryptionTargetBundle, publicKey: publicKey))
    if let encryptOtpError { throw encryptOtpError }
    return "enc(\(code))"
  }

  func clientSignatureForLogin(verificationToken: String) throws -> (message: String, publicKey: String) {
    loginMessageCalls.append(verificationToken)
    return ("login:\(verificationToken)", stubbedClientSignatureKey)
  }

  func clientSignatureForSignup(
    verificationToken: String, email: String?, phoneNumber: String?
  ) throws -> (message: String, publicKey: String) {
    signupMessageCalls.append(.init(verificationToken: verificationToken, email: email, phoneNumber: phoneNumber))
    return ("signup:\(verificationToken):\(email ?? phoneNumber ?? "")", stubbedClientSignatureKey)
  }

  func signClientMessage(_ message: String, publicKey: String) async throws -> String {
    signClientMessageCalls.append(.init(message: message, publicKey: publicKey))
    if let signClientMessageError { throw signClientMessageError }
    return "sig(\(message))"
  }

  func storeTurnkeySession(jwt: String, sessionKey: String) async throws {
    storeSessionCalls.append(.init(jwt: jwt, sessionKey: sessionKey))
    if let storeSessionError { throw storeSessionError }
    // Vendor behaviour: an occupied key refuses the store; the new session is auto-selected
    // only when none was selected.
    guard !storedSessionKeys.contains(sessionKey) else { throw TurnkeySwiftError.keyAlreadyExists }
    storedSessionKeys.insert(sessionKey)
    if selectedStoredSessionKey == nil {
      selectedStoredSessionKey = sessionKey
    }
    onStoreSession?()
  }

  struct AddAccountsCall { let walletId: String; let accounts: [WalletAccountParams] }
  var addAccountsCalls: [AddAccountsCall] = []
  var addAccountsError: Error?

  var clearStoredSessionCallCount = 0
  /// The keys passed to `clearStoredSession` (`nil` = "the selected session").
  var clearStoredSessionCalls: [String?] = []
  var createWalletCalls: [CreateWalletCall] = []
  var createWalletError: Error?

  var selectedStoredSessionKey: String?
  var selectStoredSessionCalls: [String] = []
  var selectStoredSessionError: Error?

  /// Keys with a stored session, mirroring the vendor's keychain registry. `storeTurnkeySession`
  /// and the passkey flows insert; `clearStoredSession` removes.
  var storedSessionKeys: Set<String> = []

  func selectStoredSession(sessionKey: String) async throws {
    selectStoredSessionCalls.append(sessionKey)
    if let selectStoredSessionError { throw selectStoredSessionError }
    selectedStoredSessionKey = sessionKey
  }

  func clearStoredSession(sessionKey: String?) {
    clearStoredSessionCallCount += 1
    clearStoredSessionCalls.append(sessionKey)
    storedSessionKeys.remove(sessionKey ?? selectedStoredSessionKey ?? "")
    // Vendor behaviour: only clearing the selected session (or `nil`) tears down live state;
    // purging another key touches storage only. Like the vendor, the live state flips from a
    // main-actor Task — i.e. NOT synchronously — so logout's wait-for-settle is exercised.
    if sessionKey == nil || sessionKey == selectedStoredSessionKey {
      selectedStoredSessionKey = nil
      Task { @MainActor in
        self.session = nil
        self.authState = .unAuthenticated
      }
    }
  }

  // MARK: Passkey seams

  static let passkeyDefaultSessionKey = "com.turnkey.sdk.session"

  var loginWithPasskeyCallCount = 0
  /// The organization each passkey login was scoped to (nil = parent org).
  var loginWithPasskeyOrganizationIds: [String?] = []
  var loginWithPasskeyError: Error?
  /// rpIds the registration ceremony ran for.
  var registerPasskeyCalls: [String] = []
  var registerPasskeyError: Error?
  var stubbedRegistration = PasskeyRegistration(
    challenge: "Y2hhbGxlbmdl", credentialId: "cred-1", clientDataJson: "eyJ0eXBlIjoi",
    attestationObject: "o2NmbXQ", transports: ["AUTHENTICATOR_TRANSPORT_INTERNAL"]
  )
  /// Runs after a passkey login or a signup's key login opened a session — install the new
  /// session / authState here.
  var onPasskeyAuth: (() -> Void)?

  var temporaryKeysMade: [TemporaryApiKey] = []
  struct TemporaryKeyLoginCall: Equatable { let organizationId: String; let key: TemporaryApiKey; let sessionKey: String }
  var temporaryKeyLoginCalls: [TemporaryKeyLoginCall] = []
  /// What an adopted account (no key attached) or an expired key produces.
  var temporaryKeyLoginError: Error?

  var addPasskeyCalls: [String] = [] // rpIds
  var addPasskeyError: Error?

  func loginWithTurnkeyPasskey(anchor: ASPresentationAnchor, organizationId: String?) async throws {
    loginWithPasskeyCallCount += 1
    loginWithPasskeyOrganizationIds.append(organizationId)
    if let loginWithPasskeyError { throw loginWithPasskeyError }
    try storePasskeySession()
  }

  func makeTemporaryApiKey() -> TemporaryApiKey {
    let key = TemporaryApiKey(
      publicKey: "02temp-\(temporaryKeysMade.count + 1)",
      privateKey: "priv-\(temporaryKeysMade.count + 1)"
    )
    temporaryKeysMade.append(key)
    return key
  }

  func registerPasskey(anchor: ASPresentationAnchor, rpId: String) async throws -> PasskeyRegistration {
    registerPasskeyCalls.append(rpId)
    if let registerPasskeyError { throw registerPasskeyError }
    return stubbedRegistration
  }

  func loginWithTemporaryKey(organizationId: String, key: TemporaryApiKey, sessionKey: String) async throws {
    temporaryKeyLoginCalls.append(.init(organizationId: organizationId, key: key, sessionKey: sessionKey))
    if let temporaryKeyLoginError { throw temporaryKeyLoginError }
    try await storeTurnkeySession(jwt: "jwt-signup-\(organizationId)", sessionKey: sessionKey)
    onPasskeyAuth?()
  }

  /// Vendor behaviour at 4.0.0: passkey sessions always store under the DEFAULT key (the
  /// flows' `sessionKey` parameters are ignored), an occupied key refuses the store, and the
  /// session is auto-selected only when none was selected.
  private func storePasskeySession() throws {
    guard !storedSessionKeys.contains(Self.passkeyDefaultSessionKey) else {
      throw TurnkeySwiftError.failedToLoginWithPasskey(underlying: TurnkeySwiftError.keyAlreadyExists)
    }
    storedSessionKeys.insert(Self.passkeyDefaultSessionKey)
    if selectedStoredSessionKey == nil {
      selectedStoredSessionKey = Self.passkeyDefaultSessionKey
    }
    onPasskeyAuth?()
  }

  func addPasskeyAuthenticator(anchor: ASPresentationAnchor, rpId: String) async throws {
    addPasskeyCalls.append(rpId)
    if let addPasskeyError { throw addPasskeyError }
  }

  // MARK: Contact verification seams

  struct SetContactCall: Equatable { let contact: String; let verificationToken: String? }
  var setUserEmailCalls: [SetContactCall] = []
  var setUserPhoneNumberCalls: [SetContactCall] = []
  var setUserContactError: Error?

  func setUserEmail(_ email: String, verificationToken: String?) async throws {
    setUserEmailCalls.append(SetContactCall(contact: email, verificationToken: verificationToken))
    if let setUserContactError { throw setUserContactError }
  }

  func setUserPhoneNumber(_ phone: String, verificationToken: String?) async throws {
    setUserPhoneNumberCalls.append(SetContactCall(contact: phone, verificationToken: verificationToken))
    if let setUserContactError { throw setUserContactError }
  }

  func createTurnkeyWallet(walletName: String, accounts: [WalletAccountParams], mnemonicLength: Int) async throws {
    createWalletCalls.append(CreateWalletCall(
      walletName: walletName, accounts: accounts, mnemonicLength: mnemonicLength
    ))
    if let createWalletError { throw createWalletError }
  }

  func addAccountsToTurnkeyWallet(walletId: String, accounts: [WalletAccountParams]) async throws {
    addAccountsCalls.append(AddAccountsCall(walletId: walletId, accounts: accounts))
    if let addAccountsError { throw addAccountsError }
  }

  // MARK: Key export seams

  struct ExportAccountKeyCall: Equatable { let address: String; let encoding: ExportedKeyEncoding }

  var exportMnemonicCalls: [String] = []
  var exportMnemonicError: Error?
  var stubbedMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

  var exportAccountKeyCalls: [ExportAccountKeyCall] = []
  var exportAccountKeyError: Error?
  var stubbedExportedKey = "exported-private-key"

  func exportWalletMnemonic(walletId: String) async throws -> String {
    exportMnemonicCalls.append(walletId)
    if let exportMnemonicError { throw exportMnemonicError }
    return stubbedMnemonic
  }

  func exportAccountPrivateKey(
    address: String,
    encoding: ExportedKeyEncoding
  ) async throws -> String {
    exportAccountKeyCalls.append(ExportAccountKeyCall(address: address, encoding: encoding))
    if let exportAccountKeyError { throw exportAccountKeyError }
    return stubbedExportedKey
  }

  func signRawPayload(
    signWith: String,
    payload: String,
    encoding: PayloadEncoding,
    hashFunction: HashFunction
  ) async throws -> SignRawPayloadResult {
    signRawPayloadCalls.append(
      SignRawPayloadCall(
        signWith: signWith,
        payload: payload,
        encoding: encoding,
        hashFunction: hashFunction
      )
    )

    if let signRawPayloadError {
      throw signRawPayloadError
    }

    return mockSignature
  }
}

extension MockTurnkey {
  static func defaultSession(organizationId: String = "org-id") -> Session {
    session(expiringIn: 3600, organizationId: organizationId)
  }

  /// A session whose JWT expiry has already passed.
  static func expiredSession(organizationId: String = "org-id") -> Session {
    session(expiringIn: -60, organizationId: organizationId)
  }

  /// A session inside the coordinator's refresh buffer but not yet expired.
  static func nearExpirySession(remainingSeconds: TimeInterval = 10) -> Session {
    session(expiringIn: remainingSeconds)
  }

  static func session(
    expiringIn seconds: TimeInterval,
    organizationId: String = "org-id"
  ) -> Session {
    decode(
      SessionFixture(
        exp: Date().addingTimeInterval(seconds).timeIntervalSince1970,
        publicKey: "pubkey",
        sessionType: .readWrite,
        userId: "user-id",
        organizationId: organizationId,
        token: "jwt"
      ),
      as: Session.self
    )
  }

  static func defaultWallet(address: String = defaultWalletAddress) -> Wallet {
    decode(
      WalletFixture(
        walletId: "wallet-id",
        walletName: "wallet",
        createdAt: "0",
        updatedAt: "0",
        exported: false,
        imported: false,
        accounts: [
          WalletAccount(
            address: address,
            addressFormat: .address_format_ethereum,
            createdAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            curve: .curve_secp256k1,
            organizationId: "org-id",
            path: "m/44'/60'/0'/0/0",
            pathFormat: .path_format_bip32,
            publicKey: nil,
            updatedAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            walletAccountId: "wallet-account-id",
            walletDetails: nil,
            walletId: "wallet-id"
          )
        ]
      ),
      as: Wallet.self
    )
  }

  static func makeActivity(
    id: String,
    from: String,
    to: String,
    caip2: String,
    value: String?,
    data: String?,
    sendTransactionStatusId: String?,
    status: v1ActivityStatus = .activity_status_completed,
    failureMessage: String? = nil,
    createdAtSeconds: String = "1714521600",
    gasStationNonce: String? = nil
  ) -> v1Activity {
    v1Activity(
      canApprove: false,
      canReject: false,
      createdAt: externaldatav1Timestamp(nanos: "0", seconds: createdAtSeconds),
      failure: failureMessage.map { rpcStatus(message: $0) },
      fingerprint: "fingerprint",
      id: id,
      intent: v1Intent(
        ethSendTransactionIntent: v1EthSendTransactionIntent(
          caip2: caip2,
          data: data,
          from: from,
          gasLimit: "21000",
          gasStationNonce: gasStationNonce,
          maxFeePerGas: "1000000000",
          maxPriorityFeePerGas: "1000000000",
          nonce: "1",
          sponsor: false,
          to: to,
          value: value
        )
      ),
      organizationId: "org-id",
      result: v1Result(
        ethSendTransactionResult: sendTransactionStatusId.map {
          v1EthSendTransactionResult(sendTransactionStatusId: $0)
        }
      ),
      status: status,
      type: .activity_type_eth_send_transaction,
      updatedAt: externaldatav1Timestamp(nanos: "0", seconds: createdAtSeconds),
      votes: []
    )
  }

  /// A valid base58 Solana account address (exactly 32 bytes) for fixtures.
  static let defaultSolanaAddress = Base58.encode((0..<32).map { UInt8($0 + 1) })

  /// A wallet carrying both an Ethereum and a Solana account, matching how the Turnkey demo
  /// provisions dual-curve wallets. `solanaAddress` is overridable so a test can bind the wallet
  /// to a specific on-chain fixture (e.g. a collateral account's real owner).
  static func dualCurveWallet(solanaAddress: String = defaultSolanaAddress) -> Wallet {
    decode(
      WalletFixture(
        walletId: "wallet-id",
        walletName: "wallet",
        createdAt: "0",
        updatedAt: "0",
        exported: false,
        imported: false,
        accounts: [
          WalletAccount(
            address: defaultWalletAddress,
            addressFormat: .address_format_ethereum,
            createdAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            curve: .curve_secp256k1,
            organizationId: "org-id",
            path: "m/44'/60'/0'/0/0",
            pathFormat: .path_format_bip32,
            publicKey: nil,
            updatedAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            walletAccountId: "wallet-account-id",
            walletDetails: nil,
            walletId: "wallet-id"
          ),
          WalletAccount(
            address: solanaAddress,
            addressFormat: .address_format_solana,
            createdAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            curve: .curve_ed25519,
            organizationId: "org-id",
            path: "m/44'/501'/0'/0'",
            pathFormat: .path_format_bip32,
            publicKey: nil,
            updatedAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            walletAccountId: "wallet-account-id-sol",
            walletDetails: nil,
            walletId: "wallet-id"
          )
        ]
      ),
      as: Wallet.self
    )
  }

  /// A wallet holding only a Solana account, under its own wallet id — the second seed of a
  /// legacy (pre one-seed provisioning) account.
  static func solanaOnlyWallet(solanaAddress: String = defaultSolanaAddress) -> Wallet {
    decode(
      WalletFixture(
        walletId: "wallet-id-sol",
        walletName: "wallet-sol",
        createdAt: "0",
        updatedAt: "0",
        exported: false,
        imported: false,
        accounts: [
          WalletAccount(
            address: solanaAddress,
            addressFormat: .address_format_solana,
            createdAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            curve: .curve_ed25519,
            organizationId: "org-id",
            path: "m/44'/501'/0'/0'",
            pathFormat: .path_format_bip32,
            publicKey: nil,
            updatedAt: externaldatav1Timestamp(nanos: "0", seconds: "0"),
            walletAccountId: "wallet-account-id-sol-only",
            walletDetails: nil,
            walletId: "wallet-id-sol"
          )
        ]
      ),
      as: Wallet.self
    )
  }

  static func makeSolanaActivity(
    id: String,
    signWith: String,
    caip2: String,
    unsignedTransaction: String,
    sendTransactionStatusId: String?,
    createdAtSeconds: String = "1714521600",
    status: v1ActivityStatus = .activity_status_completed,
    failureMessage: String? = nil
  ) -> v1Activity {
    v1Activity(
      canApprove: false,
      canReject: false,
      createdAt: externaldatav1Timestamp(nanos: "0", seconds: createdAtSeconds),
      failure: failureMessage.map { rpcStatus(message: $0) },
      fingerprint: "fingerprint",
      id: id,
      intent: v1Intent(
        solSendTransactionIntent: v1SolSendTransactionIntent(
          caip2: caip2,
          recentBlockhash: nil,
          signWith: signWith,
          sponsor: false,
          unsignedTransaction: unsignedTransaction
        )
      ),
      organizationId: "org-id",
      result: v1Result(
        solSendTransactionResult: sendTransactionStatusId.map {
          v1SolSendTransactionResult(sendTransactionStatusId: $0)
        }
      ),
      status: status,
      type: .activity_type_sol_send_transaction,
      updatedAt: externaldatav1Timestamp(nanos: "0", seconds: createdAtSeconds),
      votes: []
    )
  }

  static func decode<T: Decodable, Source: Encodable>(
    _ source: Source,
    as type: T.Type = T.self
  ) -> T {
    let data = try! JSONEncoder().encode(source)
    return try! JSONDecoder().decode(type, from: data)
  }
}

private struct WalletAddressBalancesResponseFixture: Encodable {
  let balances: [v1AssetBalance]?
}

private struct EthSendTransactionResponseFixture: Encodable {
  let activity: v1Activity
  let sendTransactionStatusId: String
}

private struct SolSendTransactionResponseFixture: Encodable {
  let activity: v1Activity
  let sendTransactionStatusId: String
}

private struct SendTransactionStatusResponseFixture: Encodable {
  let error: v1TxError?
  let eth: v1EthSendTransactionStatus?
  let solana: v1SolanaSendTransactionStatus?
  let txError: String?
  let txStatus: String
}

private struct ActivityResponseFixture: Encodable {
  let activity: v1Activity
}

private struct ActivitiesResponseFixture: Encodable {
  let activities: [v1Activity]
}

private struct SessionFixture: Encodable {
  let exp: TimeInterval
  let publicKey: String
  let sessionType: SessionType
  let userId: String
  let organizationId: String
  let token: String?

  enum CodingKeys: String, CodingKey {
    case exp
    case publicKey = "public_key"
    case sessionType = "session_type"
    case userId = "user_id"
    case organizationId = "organization_id"
    case token
  }
}

private struct WalletFixture: Encodable {
  let walletId: String
  let walletName: String
  let createdAt: String
  let updatedAt: String
  let exported: Bool
  let imported: Bool
  let accounts: [v1WalletAccount]
}
