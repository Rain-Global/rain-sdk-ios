import Foundation
@testable import RainCore
@testable import RainTurnkey

/// Configurable stand-in for `TurnkeyHistoryProviding`. Records every call and answers with the
/// configured responses, or throws `error` when set.
final class MockTurnkeyHistory: TurnkeyHistoryProviding, @unchecked Sendable {
  struct Call: Equatable {
    let organizationId: String
    let sessionPublicKey: String
    let address: String
    let caip2: String
    let limit: Int
  }

  var ethResponse = TurnkeyEthHistoryResponse(transactions: [])
  var solResponse = TurnkeySolHistoryResponse(transactions: [])
  var error: Error?
  private(set) var ethCalls: [Call] = []
  private(set) var solCalls: [Call] = []

  func listEthTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeyEthHistoryResponse {
    ethCalls.append(
      Call(
        organizationId: organizationId,
        sessionPublicKey: sessionPublicKey,
        address: address,
        caip2: caip2,
        limit: limit
      )
    )
    if let error { throw error }
    return ethResponse
  }

  func listSolTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeySolHistoryResponse {
    solCalls.append(
      Call(
        organizationId: organizationId,
        sessionPublicKey: sessionPublicKey,
        address: address,
        caip2: caip2,
        limit: limit
      )
    )
    if let error { throw error }
    return solResponse
  }
}

/// History stub for tests that exercise the activity-log fallback: every indexed query fails
/// the way it does for an org without the transaction history feature.
struct ThrowingTurnkeyHistory: TurnkeyHistoryProviding {
  func listEthTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeyEthHistoryResponse {
    throw TurnkeyHistoryError(statusCode: 403, body: "transaction history feature is not enabled")
  }

  func listSolTransactionHistory(
    organizationId: String,
    sessionPublicKey: String,
    address: String,
    caip2: String,
    limit: Int
  ) async throws -> TurnkeySolHistoryResponse {
    throw TurnkeyHistoryError(statusCode: 403, body: "transaction history feature is not enabled")
  }
}
