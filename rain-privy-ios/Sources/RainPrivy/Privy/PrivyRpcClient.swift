import Foundation
import RainCore

/// Minimal JSON-RPC 2.0 client for Privy's read path (balances, gas, fee estimates, and the
/// pre-broadcast `eth_call` simulation).
///
/// Privy's EIP-1193 provider is reserved for custody (sign / send); everything read-only goes
/// through here against the RPC endpoints Rain was configured with.
final class PrivyRpcClient: Sendable {
  /// What the RPC call is for; drives node-error classification.
  enum CallPurpose: Sendable {
    /// Read-only lookups (balances, gas price): node errors are infrastructure failures, never
    /// simulation verdicts.
    case read
    /// Pre-broadcast simulation / estimation (`eth_call`, `eth_estimateGas`): reverts are real
    /// verdicts about the transaction.
    case simulation
  }

  private let session: URLSession
  private let timeout: TimeInterval

  init(session: URLSession = .shared, timeout: TimeInterval = 10) {
    self.session = session
    self.timeout = timeout
  }

  /// Sends a single JSON-RPC 2.0 request and returns the `result` field as a String.
  func callForHexResult(
    rpcUrl: String,
    method: String,
    params: [Any],
    purpose: CallPurpose = .read
  ) async throws -> String {
    guard let url = URL(string: rpcUrl) else {
      throw RainError.invalidRpcUrl(rpcUrl)
    }

    do {
      var request = URLRequest(url: url, timeoutInterval: timeout)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(
        withJSONObject: [
          "jsonrpc": "2.0",
          "id": 1,
          "method": method,
          "params": params
        ]
      )

      let (data, _) = try await session.data(for: request)
      guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RainError.internalError(
          details: "Unexpected RPC response payload for method \(method)"
        )
      }

      if let error = response["error"] as? [String: Any] {
        let code = error["code"] as? Int ?? -1
        let message = error["message"] as? String ?? "Unknown RPC error"
        throw Self.classifyNodeError(code: code, message: message, purpose: purpose)
      }

      guard let result = response["result"] as? String else {
        throw RainError.internalError(
          details: "Unexpected RPC result for method \(method)"
        )
      }
      return result
    } catch let error as RainError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A cancelled URLSession call surfaces as a URL error, not CancellationError; the
      // caller walking away must never be reported as a network or provider verdict.
      if Task.isCancelled { throw CancellationError() }
      RainLogger.error("Rain SDK: Privy JSON-RPC failure for \(method): \(error)")
      throw RainError.from(underlying: error)
    }
  }

  /// Classifies a node JSON-RPC error by message, according to the call's purpose.
  /// Simulation calls treat "revert" as a simulation verdict (checked before
  /// "insufficient funds"); reads never do, since a revert on a read is an internal failure. No
  /// user-rejection keyword mapping: node errors are never user actions. Anything unrecognized
  /// falls back to `.internalError` with the code and message preserved in the details.
  private static func classifyNodeError(
    code: Int,
    message: String,
    purpose: CallPurpose
  ) -> RainError {
    let lowered = message.lowercased()
    let details = "RPC error [\(code)]: \(message)"
    switch purpose {
    case .simulation:
      if lowered.contains("revert") {
        return .transactionSimulationFailed(
          underlying: RainError.internalError(details: details)
        )
      }
      if lowered.contains("insufficient funds") {
        return .insufficientFunds(required: "unknown", available: "unknown")
      }
    case .read:
      if lowered.contains("insufficient funds") {
        return .insufficientFunds(required: "unknown", available: "unknown")
      }
    }
    return .internalError(details: details)
  }
}
