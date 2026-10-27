import Foundation
@_spi(RainAdapter) import RainCore

// MARK: - What this is
//
// The device half of Rain's embedded-wallet auth (`/v1/issuing/embedded-wallets`). It replaces
// the vendor's Auth Proxy for code send, code verify, signup and login; everything after a
// session exists stays device → Turnkey. The partner's BACKEND mints the wallet auth token
// (`wat_…`) with its Api-Key and hands it to the app; this client only ever carries that token
// as a bearer. It never sends a contact — the token is bound to one.
//
// Pure transport + decoding + error classification. No flow logic: the managed-auth controller
// decides what a 404 on login means (go sign up), how a wrong code is retried, and so on.

// MARK: - Wire types

internal struct RainApiOtpChallenge: Equatable, Decodable, Sendable {
  let otpId: String
  let otpEncryptionTargetBundle: String
}

internal struct RainApiVerification: Equatable, Decodable, Sendable {
  /// Turnkey verification token (JWT, 10 min). Carries the public key the code was encrypted to.
  let verificationToken: String
}

internal struct RainApiSignup: Equatable, Decodable, Sendable {
  let subOrganizationId: String
}

internal struct RainApiLogin: Equatable, Decodable, Sendable {
  /// Turnkey session JWT to hand to `storeSession`.
  let sessionToken: String
  let expiresAt: String
  let providerUserId: String
  /// Lowercased by the backend; checksum on display, not here.
  let walletAddress: String
  let solanaAddress: String
}

/// The vendor's `v1ClientSignature`, encoded by us so the wire shape is pinned here.
internal struct RainApiClientSignature: Equatable, Encodable, Sendable {
  static let scheme = "CLIENT_SIGNATURE_SCHEME_API_P256"

  let publicKey: String
  let message: String
  let signature: String
  var scheme: String { Self.scheme }

  private enum CodingKeys: String, CodingKey { case publicKey, scheme, message, signature }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(publicKey, forKey: .publicKey)
    try container.encode(scheme, forKey: .scheme)
    try container.encode(message, forKey: .message)
    try container.encode(signature, forKey: .signature)
  }
}

/// The body of `/signup/passkey`. `attestation` is an object — rain-api validates exactly these
/// four fields (`types.ts`) and rejects anything else — and matches the vendor's
/// `v1Attestation`, so the ceremony result maps field for field. `publicKey` is the device's
/// temporary login key (compressed P256, hex); rain-api attaches it to the new account as a
/// 60-second API key.
internal struct RainApiPasskeyAttestation: Equatable, Encodable, Sendable {
  struct Attestation: Equatable, Encodable, Sendable {
    let credentialId: String
    let clientDataJson: String
    let attestationObject: String
    /// Vendor `v1AuthenticatorTransport` raw values, e.g. `AUTHENTICATOR_TRANSPORT_INTERNAL`.
    let transports: [String]
  }

  let challenge: String
  let attestation: Attestation
  let publicKey: String
}

// MARK: - Errors

/// A device endpoint's refusal, classified from rain-api's `{ statusCode, error, message }`
/// (no machine code yet — classification keys on status and, for 400 / 409, message text).
internal struct RainApiAuthError: Error, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// 400 "Invalid or expired code": keep the attempt, the user retypes.
    case invalidCode
    /// 400 "Verification failed" / "…different email or phone": restart the attempt.
    case verificationFailed
    /// 401 expired / revoked / bad token: ask the host for a new one.
    case tokenRejected
    /// The tenant cannot use embedded wallets — 403 (flag off, wrong token kind) or 401
    /// "Invalid tenant" (no API access, not compliance-approved). A new token does not help.
    case forbidden
    /// 404 on login: no wallet for this contact in this tenant — sign up.
    case noWallet
    /// 409: token already used, signup in progress (retry within 120 s), or the passkey already
    /// has a wallet (use login).
    case conflict
    /// 429: too many codes or attempts.
    case rateLimited
    /// 5xx: Turnkey not configured for this environment, or codes cannot be sent.
    case serverError
    /// Anything else the server said that we have no name for.
    case other
  }

  let kind: Kind
  let statusCode: Int
  let message: String

  /// `RainError` for the endings the controller does not handle itself. `noWallet` is not an
  /// error to a host — the controller turns it into a signup — so it maps conservatively.
  var rainError: RainError {
    switch kind {
    case .invalidCode:
      return .invalidLoginCode
    case .tokenRejected:
      return .unauthorized(details: "Rain rejected the wallet auth token (HTTP \(statusCode)): \(message)")
    case .forbidden:
      return .unauthorized(details: "Rain refused embedded-wallet auth for this tenant (HTTP \(statusCode)): \(message)")
    case .verificationFailed, .noWallet, .conflict, .rateLimited, .serverError, .other:
      return .providerError(underlying: self)
    }
  }
}

extension RainApiAuthError: LocalizedError {
  var errorDescription: String? { "Rain API auth failed (HTTP \(statusCode), \(kind)): \(message)" }
}

// MARK: - Client

/// The device calls, each under the host-supplied wallet auth token.
internal protocol RainApiAuthClientProtocol: Sendable {
  func initOtp(token: String) async throws -> RainApiOtpChallenge
  func verifyOtp(token: String, otpId: String, encryptedOtpBundle: String) async throws -> RainApiVerification
  func signup(token: String, verificationToken: String, clientSignature: RainApiClientSignature) async throws -> RainApiSignup
  func login(
    token: String,
    verificationToken: String,
    clientSignature: RainApiClientSignature,
    subOrganizationId: String?
  ) async throws -> RainApiLogin
  func signupPasskey(token: String, attestation: RainApiPasskeyAttestation) async throws -> RainApiSignup
}

internal struct RainApiAuthClient: RainApiAuthClientProtocol {
  /// One HTTP exchange. Injected so tests drive the client without a URLProtocol.
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  static let basePath = "v1/issuing/embedded-wallets"

  private let baseURL: URL
  private let transport: Transport

  init(baseURL: URL, transport: Transport? = nil) {
    self.baseURL = baseURL
    self.transport = transport ?? Self.urlSessionTransport
  }

  // MARK: Endpoints

  func initOtp(token: String) async throws -> RainApiOtpChallenge {
    try await post("/otp/init", token: token, body: Optional<Empty>.none)
  }

  func verifyOtp(token: String, otpId: String, encryptedOtpBundle: String) async throws -> RainApiVerification {
    struct Body: Encodable { let otpId: String; let encryptedOtpBundle: String }
    return try await post("/otp/verify", token: token, body: Body(otpId: otpId, encryptedOtpBundle: encryptedOtpBundle))
  }

  func signup(token: String, verificationToken: String, clientSignature: RainApiClientSignature) async throws -> RainApiSignup {
    struct Body: Encodable { let verificationToken: String; let clientSignature: RainApiClientSignature }
    return try await post("/signup", token: token, body: Body(verificationToken: verificationToken, clientSignature: clientSignature))
  }

  func login(
    token: String,
    verificationToken: String,
    clientSignature: RainApiClientSignature,
    subOrganizationId: String?
  ) async throws -> RainApiLogin {
    struct Body: Encodable {
      let verificationToken: String
      let clientSignature: RainApiClientSignature
      let subOrganizationId: String?
    }
    return try await post(
      "/login", token: token,
      body: Body(verificationToken: verificationToken, clientSignature: clientSignature, subOrganizationId: subOrganizationId)
    )
  }

  func signupPasskey(token: String, attestation: RainApiPasskeyAttestation) async throws -> RainApiSignup {
    try await post("/signup/passkey", token: token, body: attestation)
  }

  // MARK: Plumbing

  private struct Empty: Encodable {}

  private func post<Body: Encodable, Response: Decodable>(
    _ path: String,
    token: String,
    body: Body?
  ) async throws -> Response {
    var request = URLRequest(url: baseURL.appendingPathComponent(Self.basePath + path))
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw RainError.networkError(underlying: error)
    }

    guard (200...299).contains(response.statusCode) else {
      throw Self.classify(statusCode: response.statusCode, body: data)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw RainError.internalError(details: "Rain API auth: unreadable answer from \(path): \(error)")
    }
  }

  /// rain-api's error body: `{ statusCode, error, message }`.
  private struct ErrorBody: Decodable {
    let message: String?
  }

  internal static func classify(statusCode: Int, body: Data) -> RainApiAuthError {
    let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message
      ?? String(decoding: body.prefix(200), as: UTF8.self)
    let lower = message.lowercased()
    let kind: RainApiAuthError.Kind
    switch statusCode {
    case 400:
      // "Invalid or expired code" is the only 400 the user can fix by retyping. Match the
      // whole phrase: /otp/init's "This contact can't receive a code" is also a 400 and must
      // not read as a wrong code before any code was sent.
      kind = lower.contains("invalid or expired code") ? .invalidCode : .verificationFailed
    case 401:
      // "Invalid tenant" (no API access, or not compliance-approved) is also a 401, but a new
      // token would fail the same way — classify it with the tenant refusals so the controller
      // never loops on the host's token provider.
      kind = lower.contains("invalid tenant") ? .forbidden : .tokenRejected
    case 403: kind = .forbidden
    case 404: kind = .noWallet
    case 409: kind = .conflict
    case 429: kind = .rateLimited
    case 500...599: kind = .serverError
    default: kind = .other
    }
    return RainApiAuthError(kind: kind, statusCode: statusCode, message: message)
  }

  private static let urlSessionTransport: Transport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, http)
  }
}
