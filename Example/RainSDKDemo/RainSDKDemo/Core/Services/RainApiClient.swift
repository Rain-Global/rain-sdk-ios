import Foundation
import RainCore
import RainWallet // RainWalletContact, for the wallet auth token mint

// The Rain issuing API is the HOST's responsibility, not the SDK's: the SDK builds and sends
// transactions, while the data those transactions need — the user's collateral contract and
// Rain's admin withdrawal signature — comes from Rain's REST API, authenticated with a program
// Api-Key that belongs on the partner's side. This file is the demo's own minimal client and a
// reference for what a host app implements (typically on its backend, so the key never ships in
// the app).

// MARK: - Environment

/// Which Rain deployment the demo talks to.
enum RainApiEnvironment {
  /// Rain sandbox (`api-dev.rain.xyz`).
  case sandbox
  /// Rain production (`api.rain.xyz`). Mainnet: real USDC, real gas.
  case production

  var baseURL: URL {
    switch self {
    case .sandbox: return URL(string: "https://api-dev.rain.xyz")!
    case .production: return URL(string: "https://api.rain.xyz")!
    }
  }
}

// MARK: - Models

/// A user's collateral contract (`GET /v1/issuing/users/{userId}/contracts`).
struct CollateralContract: Sendable, Equatable {
  let id: String?
  let chainId: Int
  /// The collateral proxy holding the assets — `RainWithdrawAddresses.proxyAddress`.
  let proxyAddress: String
  /// The controller a withdrawal executes against — `RainWithdrawAddresses.controllerAddress`.
  let controllerAddress: String
  /// Where deposits go when Rain provides a dedicated address (Solana); otherwise the proxy.
  let depositAddress: String?
  /// Admin signers; one of these is passed as `adminAddress` when requesting a signature.
  let adminAddresses: [String]
  let contractVersion: Int?
  let tokens: [CollateralToken]
}

/// A token held in a collateral contract. Name/symbol/decimals are not on the wire — the SDK
/// resolves them from the address via `RainSdk.tokenMetadata(chainId:address:)` (see
/// `RainSDKService.fetchCollateralContract(for:)`).
struct CollateralToken: Sendable, Equatable {
  let address: String
  /// Balance as a decimal string in whole tokens (not base units).
  let balance: String
  let exchangeRate: Double
  let advanceRate: Double
  var name: String?
  var symbol: String?
  var decimals: Int?

  var balanceAmount: Decimal? { AmountHelpers.strictDecimal(from: balance) }
}

// MARK: - Errors

enum RainApiError: LocalizedError {
  /// 401/403: wrong or insufficient Api-Key.
  case unauthorized
  /// Any other non-2xx status, with a snippet of the body.
  case http(statusCode: Int, message: String?)
  /// Rain has not produced the withdrawal signature yet — retry after `retryAfter` seconds.
  case signatureNotReady(status: String, retryAfter: Int?)
  case decoding(Error)
  case transport(Error)

  var errorDescription: String? {
    switch self {
    case .unauthorized:
      return "Rain API rejected the Api-Key (401/403)."
    case .http(let statusCode, let message):
      return "Rain API error \(statusCode)\(message.map { ": \($0)" } ?? "")."
    case .signatureNotReady(let status, let retryAfter):
      return "Withdrawal signature not ready: status=\(status)\(retryAfter.map { " (retry after \($0)s)" } ?? "")."
    case .decoding(let error):
      return "Rain API response could not be decoded: \(error.localizedDescription)"
    case .transport(let error):
      return "Rain API request failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - Client

/// Minimal `URLSession` client for the two Rain API calls the wallet flows need. Every request
/// authenticates with the program key in the `Api-Key` header.
final class RainApiClient: Sendable {
  private let baseURL: URL
  private let apiKey: String
  private let userId: String
  private let session: URLSession
  private let decoder = JSONDecoder()

  private static let maxErrorBodyChars = 300

  init(environment: RainApiEnvironment, apiKey: String, userId: String, session: URLSession? = nil) {
    self.baseURL = environment.baseURL
    self.apiKey = apiKey
    self.userId = userId
    self.session = session ?? {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = 30
      return URLSession(configuration: configuration)
    }()
  }

  // MARK: Endpoints

  /// `GET /v1/issuing/users/{userId}/contracts`. Tokens come back with nil name/symbol/decimals —
  /// resolve them through the SDK (`RainSdk.tokenMetadata`).
  func fetchCollateralContracts() async throws -> [CollateralContract] {
    var request = URLRequest(url: url(path: "v1/issuing/users/\(userId)/contracts"))
    request.httpMethod = "GET"
    applyHeaders(&request)

    let data = try await execute(request, operation: "fetch contracts")
    let dtos: [ContractDto]
    do {
      dtos = try decoder.decode([ContractDto].self, from: data)
    } catch {
      throw RainApiError.decoding(error)
    }
    return dtos.map { dto in
      let chainId = dto.chainId ?? 0
      return CollateralContract(
        id: dto.id?.isEmpty == false ? dto.id : nil,
        chainId: chainId,
        proxyAddress: dto.proxyAddress ?? "",
        controllerAddress: dto.controllerAddress ?? "",
        depositAddress: dto.depositAddress?.isEmpty == false ? dto.depositAddress : nil,
        adminAddresses: dto.adminAddresses ?? [],
        contractVersion: dto.contractVersion,
        tokens: (dto.tokens ?? []).map { token in
          CollateralToken(
            address: token.address ?? "",
            balance: token.balance ?? "",
            exchangeRate: token.exchangeRate ?? 0,
            advanceRate: token.advanceRate ?? 0
          )
        }
      )
    }
  }

  /// `GET /v1/issuing/users/{userId}/signatures/withdrawals` — Rain's authorization for one
  /// withdrawal, passed whole to `RainClient.withdrawCollateral` / `prepareWithdrawal`.
  ///
  /// - Parameter amountBaseUnits: Withdrawal amount in the token's base units (decimal string).
  /// - Throws: `RainApiError.signatureNotReady` until Rain has produced the signature.
  func fetchAdminSignature(
    chainId: Int,
    tokenAddress: String,
    amountBaseUnits: String,
    adminAddress: String,
    recipientAddress: String,
    isAmountNative: Bool = true
  ) async throws -> RainAdminSignature {
    let queryItems = [
      URLQueryItem(name: "chainId", value: String(chainId)),
      URLQueryItem(name: "token", value: tokenAddress),
      URLQueryItem(name: "amount", value: amountBaseUnits),
      URLQueryItem(name: "adminAddress", value: adminAddress),
      URLQueryItem(name: "recipientAddress", value: recipientAddress),
      URLQueryItem(name: "isAmountNative", value: isAmountNative ? "true" : "false"),
    ]
    var request = URLRequest(
      url: url(path: "v1/issuing/users/\(userId)/signatures/withdrawals", queryItems: queryItems)
    )
    request.httpMethod = "GET"
    applyHeaders(&request)

    let data = try await execute(request, operation: "fetch withdrawal signature")
    let response: WithdrawalSignatureResponse
    do {
      response = try decoder.decode(WithdrawalSignatureResponse.self, from: data)
    } catch {
      throw RainApiError.decoding(error)
    }

    let status = response.status ?? ""
    // "ready" without signature bytes is still not ready — an empty signature would only
    // surface later as a confusing on-chain revert.
    guard status.lowercased() == "ready",
          let signatureData = response.signature?.data, !signatureData.isEmpty
    else {
      let trimmed = status.trimmingCharacters(in: .whitespaces)
      throw RainApiError.signatureNotReady(
        status: trimmed.isEmpty ? "unknown" : trimmed,
        retryAfter: response.retryAfter
      )
    }
    return RainAdminSignature(
      salt: response.signature?.salt ?? "",
      signature: signatureData,
      expiresAt: response.expiresAt ?? ""
    )
  }

  /// `POST /v1/issuing/embedded-wallets/auth-tokens` — mints a wallet auth token (`wat_…`) the
  /// Rain wallet's code login rides on. Bound to `contact`; `nil` mints a contact-less token,
  /// which only passkey signup accepts. Ten-minute TTL, consumed by login.
  ///
  /// DEMO ONLY. This call needs the program Api-Key, which belongs on YOUR BACKEND: in a real
  /// app the backend mints the token and the app's `authTokenProvider` fetches it from there.
  /// The sample keeps the key on the Home screen so the flow can be exercised end to end.
  func mintWalletAuthToken(contact: RainWalletContact?) async throws -> String {
    struct ContactDto: Encodable { let type: String; let value: String }
    struct Body: Encodable { let contact: ContactDto? }
    struct Response: Decodable { let token: String }

    let contactDto: ContactDto? = switch contact {
    case .email(let value): ContactDto(type: "email", value: value)
    case .phone(let value): ContactDto(type: "phone", value: value)
    case nil: nil
    }
    var request = URLRequest(url: url(path: "v1/issuing/embedded-wallets/auth-tokens"))
    request.httpMethod = "POST"
    applyHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(Body(contact: contactDto))

    let data = try await execute(request, operation: "mint wallet auth token")
    do {
      return try decoder.decode(Response.self, from: data).token
    } catch {
      throw RainApiError.decoding(error)
    }
  }

  // MARK: Wire DTOs

  private struct ContractDto: Decodable {
    let id: String?
    let chainId: Int?
    let controllerAddress: String?
    let proxyAddress: String?
    let depositAddress: String?
    let adminAddresses: [String]?
    let contractVersion: Int?
    let tokens: [ContractTokenDto]?
  }

  private struct ContractTokenDto: Decodable {
    let address: String?
    let balance: String?
    let exchangeRate: Double?
    let advanceRate: Double?
  }

  private struct WithdrawalSignatureResponse: Decodable {
    struct Signature: Decodable {
      let data: String?
      let salt: String?
    }
    let status: String?
    let retryAfter: Int?
    let signature: Signature?
    let expiresAt: String?
  }

  // MARK: Internals

  private func url(path: String, queryItems: [URLQueryItem]? = nil) -> URL {
    let full = baseURL.appendingPathComponent(path)
    guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else { return full }
    if let queryItems, !queryItems.isEmpty { components.queryItems = queryItems }
    return components.url ?? full
  }

  private func applyHeaders(_ request: inout URLRequest) {
    request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }

  /// Returns the body on 2xx; 401/403 → `.unauthorized`, other non-2xx → `.http`, transport
  /// failures → `.transport`.
  private func execute(_ request: URLRequest, operation: String) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      SampleLog.e("RainApi", "\(operation) transport failure: \(error.localizedDescription)")
      throw RainApiError.transport(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw RainApiError.transport(
        NSError(domain: "RainApi", code: -1, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
      )
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      SampleLog.e("RainApi", "\(operation) rejected with \(http.statusCode)")
      throw RainApiError.unauthorized
    }
    guard (200...299).contains(http.statusCode) else {
      SampleLog.e("RainApi", "\(operation) failed with \(http.statusCode)")
      throw RainApiError.http(statusCode: http.statusCode, message: Self.snippet(of: data))
    }
    return data
  }

  private static func snippet(of data: Data) -> String? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(maxErrorBodyChars))
  }
}
