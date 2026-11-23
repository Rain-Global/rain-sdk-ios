import Foundation
import TurnkeyHttp
import TurnkeyStamper
import RainCore

/// Turnkey's indexed transaction-history queries (`list_eth_transaction_history` /
/// `list_sol_transaction_history`). These cover the wallet's full on-chain history, receives
/// included, unlike the activity log, which only records what was sent through Turnkey.
///
/// The Turnkey Swift SDK does not expose these endpoints yet, so this client issues the stamped
/// REST calls directly, signing each request body with the session's on-device P-256 key exactly
/// as the SDK's own client does.
///
/// Note: Turnkey gates these queries behind a per-organization feature flag; a 403 with
/// "transaction history feature is not enabled" means the flag is off for the parent org.
internal protocol TurnkeyHistoryProviding: Sendable {
  func listEthTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeyEthHistoryResponse

  func listSolTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeySolHistoryResponse
}

/// Raised when Turnkey answers a history query with a non-2xx status.
internal struct TurnkeyHistoryError: Error, CustomStringConvertible {
  let statusCode: Int
  let body: String

  var description: String {
    "Turnkey history query failed with HTTP \(statusCode): \(body)"
  }
}

// MARK: - Wire models (hand-rolled; the Swift SDK has no types for these queries)

// Collection fields decode as optionals (synthesized Decodable has no key-absent defaults)
// and are normalized to empty at the use sites.
internal struct TurnkeyEthHistoryResponse: Decodable, Sendable {
  var transactions: [TurnkeyEthHistoryTransaction]?
}

internal struct TurnkeyEthHistoryTransaction: Decodable, Sendable {
  let transactionHash: String
  var block: TurnkeyHistoryBlock?
  var status: String?
  var from: String?
  var to: String?
  var transfers: [TurnkeyHistoryTransfer]?
  var turnkey: TurnkeyHistoryOrigin?
}

internal struct TurnkeySolHistoryResponse: Decodable, Sendable {
  var transactions: [TurnkeySolHistoryTransaction]?
}

internal struct TurnkeySolHistoryTransaction: Decodable, Sendable {
  let signature: String
  var block: TurnkeyHistoryBlock?
  var status: String?
  var feePayer: String?
  var transfers: [TurnkeyHistoryTransfer]?
  var turnkey: TurnkeyHistoryOrigin?
}

internal struct TurnkeyHistoryBlock: Decodable, Sendable {
  var number: String?
  var hash: String?
  /// RFC 3339 block timestamp.
  var timestamp: String?
}

internal struct TurnkeyHistoryTransfer: Decodable, Sendable {
  /// `IN` or `OUT`, relative to the queried address.
  var direction: String?
  var asset: TurnkeyHistoryAsset?
  /// Amount in the asset's atomic units, as a decimal string.
  var amount: String?
  var counterparty: String?
  var display: TurnkeyHistoryDisplay?
}

internal struct TurnkeyHistoryAsset: Decodable, Sendable {
  var caip19: String?
  var symbol: String?
  var name: String?
  var decimals: Int?
}

internal struct TurnkeyHistoryDisplay: Decodable, Sendable {
  var crypto: String?
  var usd: String?
}

internal struct TurnkeyHistoryOrigin: Decodable, Sendable {
  var sponsored: Bool?
}

// MARK: - Client

/// `baseURL` defaults to Turnkey's public API. A `TurnkeyContext` configured with a custom
/// `apiUrl` is not visible from here, so a host on a non-default Turnkey endpoint must pass the
/// matching base URL when this becomes constructible from the outside.
internal struct TurnkeyHistoryClient: TurnkeyHistoryProviding {
  /// Signs a request body with the session key, returning the stamp header as (name, value).
  /// Seam for unit tests.
  typealias Stamp = @Sendable (_ sessionPublicKey: String, _ payload: String) async throws
    -> (name: String, value: String)
  /// Executes the request. Seam for unit tests; production uses `URLSession.shared`.
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  private enum Path {
    static let eth = "/public/v1/query/list_eth_transaction_history"
    static let sol = "/public/v1/query/list_sol_transaction_history"
  }

  private static let errorBodyPreviewChars = 500

  private let baseURL: URL
  private let stamp: Stamp
  private let transport: Transport

  init(
    baseURL: URL = URL(string: TurnkeyClient.baseURLString)!,
    stamp: @escaping Stamp = TurnkeyHistoryClient.sessionKeyStamp,
    transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
  ) {
    self.baseURL = baseURL
    self.stamp = stamp
    self.transport = transport
  }

  /// Default stamp: the session's public key resolves the on-device private key, matching how
  /// `TurnkeyContext` signs its own requests.
  static let sessionKeyStamp: Stamp = { sessionPublicKey, payload in
    let stamper = try Stamper(apiPublicKey: sessionPublicKey, onDevicePreference: .auto)
    let (name, value) = try await stamper.stamp(payload: payload)
    return (name, value)
  }

  func listEthTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeyEthHistoryResponse {
    try await post(
      path: Path.eth,
      organizationId: organizationId,
      sessionPublicKey: sessionPublicKey,
      address: address,
      caip2: caip2,
      limit: limit
    )
  }

  func listSolTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeySolHistoryResponse {
    try await post(
      path: Path.sol,
      organizationId: organizationId,
      sessionPublicKey: sessionPublicKey,
      address: address,
      caip2: caip2,
      limit: limit
    )
  }

  private struct HistoryRequest: Encodable {
    struct Pagination: Encodable {
      // The API is proto3-JSON and rejects a numeric limit; it must be a string.
      let limit: String
    }

    let organizationId: String
    let address: String
    let caip2: String
    let paginationOptions: Pagination
  }

  private func post<Response: Decodable>(
    path: String,
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> Response {
    let body = try JSONEncoder().encode(
      HistoryRequest(
        organizationId: organizationId,
        address: address,
        caip2: caip2,
        paginationOptions: HistoryRequest.Pagination(limit: String(limit))
      )
    )
    guard let payload = String(data: body, encoding: .utf8) else {
      throw TurnkeyHistoryError(statusCode: 0, body: "request body is not valid UTF-8")
    }
    // The stamp signs the exact bytes sent, so the same encoding must be stamped and posted.
    let header = try await stamp(sessionPublicKey, payload)

    guard let url = URL(string: baseURL.absoluteString + path) else {
      throw TurnkeyHistoryError(statusCode: 0, body: "invalid history URL for path \(path)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(header.value, forHTTPHeaderField: header.name)

    let (data, response) = try await transport(request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...299).contains(statusCode) else {
      let text = String(data: data, encoding: .utf8) ?? ""
      throw TurnkeyHistoryError(
        statusCode: statusCode,
        body: String(text.prefix(Self.errorBodyPreviewChars))
      )
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}
