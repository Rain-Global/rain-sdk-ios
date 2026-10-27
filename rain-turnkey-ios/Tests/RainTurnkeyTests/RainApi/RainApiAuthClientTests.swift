import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// Wire contract of the device half of Rain's embedded-wallet auth: paths, headers, bodies,
/// decoding, and the error classification the controller keys on. No flow logic here.
@Suite("Rain API Auth Client Tests")
struct RainApiAuthClientTests {
  private let base = URL(string: "https://api-dev.rain.xyz")!

  /// Records every request and answers from a queue of (status, body).
  private final class Recorder: @unchecked Sendable {
    var requests: [URLRequest] = []
    var answers: [(Int, String)] = []
    var transportError: Error?

    var transport: RainApiAuthClient.Transport {
      { [self] request in
        requests.append(request)
        if let transportError { throw transportError }
        let (status, body) = answers.isEmpty ? (200, "{}") : answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
      }
    }

    func json(_ index: Int = 0) -> [String: Any] {
      let body = requests[index].httpBody ?? Data()
      return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
  }

  private func client(_ recorder: Recorder) -> RainApiAuthClient {
    RainApiAuthClient(baseURL: base, transport: recorder.transport)
  }

  // MARK: - Requests

  @Test("every call POSTs under the embedded-wallets base path with the token as a bearer")
  func pathsAndHeaders() async throws {
    let recorder = Recorder()
    recorder.answers = [
      (200, #"{"otpId":"otp-1","otpEncryptionTargetBundle":"bundle"}"#),
      (200, #"{"verificationToken":"vt"}"#),
      (200, #"{"subOrganizationId":"sub-1"}"#),
      (200, #"{"sessionToken":"jwt","expiresAt":"2026-10-20T00:00:00Z","providerUserId":"u","walletAddress":"0xabc","solanaAddress":"So1"}"#),
      (200, #"{"subOrganizationId":"sub-2"}"#),
    ]
    let c = client(recorder)
    let signature = RainApiClientSignature(publicKey: "pk", message: "m", signature: "sig")

    _ = try await c.initOtp(token: "wat_1")
    _ = try await c.verifyOtp(token: "wat_1", otpId: "otp-1", encryptedOtpBundle: "enc")
    _ = try await c.signup(token: "wat_1", verificationToken: "vt", clientSignature: signature)
    _ = try await c.login(token: "wat_1", verificationToken: "vt", clientSignature: signature, subOrganizationId: nil)
    _ = try await c.signupPasskey(token: "wat_2", attestation: Self.passkeyAttestation)

    let paths = recorder.requests.map { $0.url!.path }
    #expect(paths == [
      "/v1/issuing/embedded-wallets/otp/init",
      "/v1/issuing/embedded-wallets/otp/verify",
      "/v1/issuing/embedded-wallets/signup",
      "/v1/issuing/embedded-wallets/login",
      "/v1/issuing/embedded-wallets/signup/passkey",
    ])
    #expect(recorder.requests.allSatisfy { $0.httpMethod == "POST" })
    #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer wat_1")
    #expect(recorder.requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer wat_2")
    // The device never sends a contact: the token is bound to one.
    #expect(recorder.requests[0].httpBody == nil)
    for request in recorder.requests.dropFirst() {
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("contact") == false)
    }
  }

  @Test("/otp/verify reports the contact's saved wallet when there is one, and decodes without the field on older backends")
  func verifyReportsSavedWallet() async throws {
    let recorder = Recorder()
    recorder.answers = [
      (200, #"{"verificationToken":"vt","walletSubOrganizationId":"sub-7"}"#),
      (200, #"{"verificationToken":"vt","walletSubOrganizationId":null}"#),
      (200, #"{"verificationToken":"vt"}"#),
    ]
    let c = client(recorder)
    let owned = try await c.verifyOtp(token: "wat", otpId: "o", encryptedOtpBundle: "e")
    let free = try await c.verifyOtp(token: "wat", otpId: "o", encryptedOtpBundle: "e")
    let legacy = try await c.verifyOtp(token: "wat", otpId: "o", encryptedOtpBundle: "e")
    #expect(owned.walletSubOrganizationId == "sub-7")
    #expect(free.walletSubOrganizationId == nil)
    #expect(legacy.walletSubOrganizationId == nil)
  }

  @Test("the client signature is encoded in the vendor's v1ClientSignature shape")
  func clientSignatureShape() async throws {
    let recorder = Recorder()
    recorder.answers = [(200, #"{"sessionToken":"jwt","expiresAt":"x","providerUserId":"u","walletAddress":"0x","solanaAddress":"s"}"#)]
    _ = try await client(recorder).login(
      token: "wat", verificationToken: "vt",
      clientSignature: RainApiClientSignature(publicKey: "04pk", message: "{\"tokenId\":1}", signature: "ab"),
      subOrganizationId: "sub-9"
    )
    let body = recorder.json()
    let signature = body["clientSignature"] as? [String: Any]
    #expect(signature?["publicKey"] as? String == "04pk")
    #expect(signature?["scheme"] as? String == "CLIENT_SIGNATURE_SCHEME_API_P256")
    #expect(signature?["message"] as? String == "{\"tokenId\":1}")
    #expect(signature?["signature"] as? String == "ab")
    #expect(body["verificationToken"] as? String == "vt")
    #expect(body["subOrganizationId"] as? String == "sub-9")
  }

  private static let passkeyAttestation = RainApiPasskeyAttestation(
    challenge: "Y2hhbGxlbmdl",
    attestation: .init(
      credentialId: "cred-1", clientDataJson: "eyJ0eXBlIjoi", attestationObject: "o2NmbXQ",
      transports: ["AUTHENTICATOR_TRANSPORT_INTERNAL", "AUTHENTICATOR_TRANSPORT_HYBRID"]
    ),
    publicKey: "02a1b2c3"
  )

  @Test("the passkey signup body is the challenge, the four-field attestation object and the device's login key")
  func passkeyAttestationShape() async throws {
    let recorder = Recorder()
    recorder.answers = [(200, #"{"subOrganizationId":"sub-2"}"#)]
    _ = try await client(recorder).signupPasskey(token: "wat", attestation: Self.passkeyAttestation)

    let body = recorder.json()
    #expect(body["challenge"] as? String == "Y2hhbGxlbmdl")
    let attestation = body["attestation"] as? [String: Any]
    #expect(attestation?["credentialId"] as? String == "cred-1")
    #expect(attestation?["clientDataJson"] as? String == "eyJ0eXBlIjoi")
    #expect(attestation?["attestationObject"] as? String == "o2NmbXQ")
    #expect(attestation?["transports"] as? [String] == ["AUTHENTICATOR_TRANSPORT_INTERNAL", "AUTHENTICATOR_TRANSPORT_HYBRID"])
    // rain-api rejects unknown keys, so nothing else may ride along.
    #expect(Set(attestation?.keys.map { $0 } ?? []) == ["credentialId", "clientDataJson", "attestationObject", "transports"])
    #expect(body["publicKey"] as? String == "02a1b2c3")
    #expect(Set(body.keys) == ["challenge", "attestation", "publicKey"])
  }

  @Test("login without a sub-organization id omits the key rather than sending null")
  func loginOmitsNilSubOrg() async throws {
    let recorder = Recorder()
    recorder.answers = [(200, #"{"sessionToken":"jwt","expiresAt":"x","providerUserId":"u","walletAddress":"0x","solanaAddress":"s"}"#)]
    _ = try await client(recorder).login(
      token: "wat", verificationToken: "vt",
      clientSignature: RainApiClientSignature(publicKey: "pk", message: "m", signature: "s"),
      subOrganizationId: nil
    )
    #expect(recorder.json()["subOrganizationId"] == nil)
  }

  // MARK: - Responses

  @Test("a login answer decodes every field the controller needs")
  func loginDecodes() async throws {
    let recorder = Recorder()
    recorder.answers = [(200, #"{"sessionToken":"jwt-1","expiresAt":"2026-10-20T10:15:00Z","providerUserId":"user-1","walletAddress":"0xeddf67f4b6ba6da613cc1c24433073d6ab4c885d","solanaAddress":"7YP827Y77YQTU7MS8R9JGMVJKAkvyiBg6sEVJNeRibge"}"#)]
    let login = try await client(recorder).login(
      token: "wat", verificationToken: "vt",
      clientSignature: RainApiClientSignature(publicKey: "pk", message: "m", signature: "s"),
      subOrganizationId: nil
    )
    #expect(login == RainApiLogin(
      sessionToken: "jwt-1", expiresAt: "2026-10-20T10:15:00Z", providerUserId: "user-1",
      walletAddress: "0xeddf67f4b6ba6da613cc1c24433073d6ab4c885d",
      solanaAddress: "7YP827Y77YQTU7MS8R9JGMVJKAkvyiBg6sEVJNeRibge"
    ))
  }

  @Test("an unreadable 200 is an internal error, not a provider one")
  func unreadableAnswer() async throws {
    let recorder = Recorder()
    recorder.answers = [(200, "<html>")]
    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await client(recorder).initOtp(token: "wat")
    }
  }

  // MARK: - Errors

  @Test(
    "status and message classify into the kinds the controller branches on",
    arguments: [
      (400, "Invalid or expired code", RainApiAuthError.Kind.invalidCode),
      (400, "Verification failed", .verificationFailed),
      (400, "This contact can't receive a code", .verificationFailed),
      (400, "Token was issued for a different email or phone", .verificationFailed),
      (401, "Token expired", .tokenRejected),
      (401, "Bad token", .tokenRejected),
      (401, "Invalid tenant", .forbidden),
      (403, "Feature not enabled for tenant", .forbidden),
      (404, "No wallet exists for this contact", .noWallet),
      (409, "Token already used", .conflict),
      (409, "Signup in progress", .conflict),
      (429, "Too many attempts", .rateLimited),
      (503, "Turnkey is not configured", .serverError),
      (418, "teapot", .other),
    ]
  )
  func classification(status: Int, message: String, kind: RainApiAuthError.Kind) async {
    let recorder = Recorder()
    recorder.answers = [(status, #"{"statusCode":\#(status),"error":"E","message":"\#(message)"}"#)]
    do {
      _ = try await client(recorder).initOtp(token: "wat")
      Issue.record("expected a RainApiAuthError")
    } catch let error as RainApiAuthError {
      #expect(error.kind == kind)
      #expect(error.statusCode == status)
      #expect(error.message == message)
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test("a non-JSON error body still classifies, keeping a prefix of the body as the message")
  func nonJsonErrorBody() {
    let error = RainApiAuthClient.classify(statusCode: 502, body: Data("<html>bad gateway</html>".utf8))
    #expect(error.kind == .serverError)
    #expect(error.message == "<html>bad gateway</html>")
  }

  @Test("RainError mapping: a wrong code is RAIN_203, a bad token RAIN_202, the rest provider errors")
  func rainErrorMapping() {
    func error(_ kind: RainApiAuthError.Kind, _ status: Int) -> RainApiAuthError {
      RainApiAuthError(kind: kind, statusCode: status, message: "m")
    }
    #expect(error(.invalidCode, 400).rainError == .invalidLoginCode)
    #expect(error(.tokenRejected, 401).rainError == .unauthorized())
    #expect(error(.forbidden, 403).rainError == .unauthorized())
    for kind in [RainApiAuthError.Kind.verificationFailed, .noWallet, .conflict, .rateLimited, .serverError, .other] {
      #expect(error(kind, 500).rainError.code == "RAIN_501", "\(kind)")
    }
  }

  @Test("a transport failure is networkError; a cancelled task is CancellationError")
  func transportFailures() async {
    let recorder = Recorder()
    recorder.transportError = URLError(.notConnectedToInternet)
    await #expect(throws: RainError.networkError(underlying: URLError(.cancelled))) {
      _ = try await client(recorder).initOtp(token: "wat")
    }

    recorder.transportError = CancellationError()
    await #expect(throws: CancellationError.self) {
      _ = try await client(recorder).initOtp(token: "wat")
    }
  }
}
