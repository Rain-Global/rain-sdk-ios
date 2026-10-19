import Foundation

/// Minimal JSON-RPC 2.0 client used by the SDK's chain-read layer.
///
/// Owned by `EVMChainReader` and reused by `TurnkeyWalletProviderAdapter` for its
/// `eth_*` calls (gas, nonce, transaction submission helpers), so the SDK has one
/// HTTP+JSON-RPC implementation rather than per-adapter copies.
///
/// Stays small on purpose — wire format and error mapping match what
/// `TurnkeyWalletProviderAdapter.rpcRequest` did historically.
@_spi(RainAdapter) public final class JsonRpcClient: Sendable {
  private let session: URLSession
  private let timeout: TimeInterval

  @_spi(RainAdapter) public init(
    session: URLSession = .shared,
    timeout: TimeInterval = 10
  ) {
    self.session = session
    self.timeout = timeout
  }

  /// Sends a single JSON-RPC 2.0 request and returns the parsed response dictionary.
  /// Throws `RainError.invalidRpcUrl` on bad URLs, `.internalError` on malformed
  /// payloads, and wraps RPC `error` objects as `NSError(domain: "eth.rpc", ...)` mapped
  /// through `RainError.from(underlying:)`.
  internal func call(
    rpcUrl: String,
    method: String,
    params: [Any]
  ) async throws -> [String: Any] {
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
        let rpcError = NSError(
          domain: "eth.rpc",
          code: code,
          userInfo: [NSLocalizedDescriptionKey: message]
        )
        // A revert is an execution verdict, not an internal fault: map to
        // `.transactionSimulationFailed` (RAIN_403), as the Privy and Portal clients do.
        if message.range(of: "revert", options: .caseInsensitive) != nil {
          throw RainError.transactionSimulationFailed(underlying: rpcError)
        }
        throw rpcError
      }

      return response
    } catch let error as RainError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A cancelled URLSession call surfaces as a URL error, not CancellationError; the
      // caller walking away must never be reported as a network or provider verdict.
      if Task.isCancelled { throw CancellationError() }
      throw RainError.from(underlying: error)
    }
  }

  /// Convenience wrapper that extracts the `result` field as a String.
  /// Throws `.internalError` if the field is missing or not a string.
  @_spi(RainAdapter) public func callForHexResult(
    rpcUrl: String,
    method: String,
    params: [Any]
  ) async throws -> String {
    let response = try await call(rpcUrl: rpcUrl, method: method, params: params)
    guard let result = response["result"] as? String else {
      throw RainError.internalError(
        details: "Unexpected RPC result for method \(method)"
      )
    }
    return result
  }
}
