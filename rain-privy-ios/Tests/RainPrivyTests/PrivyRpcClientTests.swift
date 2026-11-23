import Testing
import Foundation
import RainCore
@testable import RainPrivy

/// Wire-format coverage: node `error` objects classify purpose-aware inside the client,
/// transport failures and non-JSON bodies go through `RainError.from(underlying:)`.
@Suite("Privy RPC Client Tests")
struct PrivyRpcClientTests {
  private func client() -> PrivyRpcClient {
    PrivyRpcClient(session: StubURLProtocol.makeSession())
  }

  @Test("refuses a redirect from https to http")
  func refusesRedirectToHttp() async throws {
    let error = await #expect(throws: RainError.self) {
      _ = try await PrivyRpcClient(session: PrivyRedirectingURLProtocol.makeSession())
        .callForHexResult(rpcUrl: "https://rpc-redirect.rpc/v3/secret-key", method: "eth_chainId", params: [])
    }
    #expect(error?.code == "RAIN_301")
    #expect(error?.localizedDescription.contains("secret-key") == false)
    #expect(PrivyRedirectingURLProtocol.plainHttpRequests == 0)
  }

  @Test("returns the hex result on a well-formed response")
  func wellFormedResult() async throws {
    let host = "rpc-ok.rpc"
    StubURLProtocol.setHandler(host: host) { _ in RpcStub.result("0x2a") }

    let result = try await client().callForHexResult(
      rpcUrl: "https://\(host)/", method: "eth_getBalance", params: ["0xabc", "latest"])
    #expect(result == "0x2a")
  }

  @Test("surfaces an unrecognized JSON-RPC error object as internalError with code and message")
  func rpcErrorObject() async {
    let host = "rpc-err.rpc"
    StubURLProtocol.setHandler(host: host) { _ in RpcStub.error(code: -32000, message: "boom") }

    do {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_call", params: [])
      Issue.record("expected an error")
    } catch let error as RainError {
      // The node's own code and message must survive classification in the details.
      #expect(error.code == "RAIN_502")
      #expect(error.localizedDescription.contains("boom"))
      #expect(error.localizedDescription.contains("-32000"))
    } catch {
      Issue.record("expected RainError, got \(error)")
    }
  }

  // MARK: - Purpose-aware node-error classification

  @Test("simulation: a revert maps to transactionSimulationFailed")
  func simulationRevertClassifies() async {
    let host = "rpc-sim-revert.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: 3, message: "execution reverted")
    }

    await #expect(throws: RainError.transactionSimulationFailed(underlying: NSError(domain: "", code: 0))) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_call", params: [], purpose: .simulation)
    }
  }

  @Test("simulation: code 3 alone, or a revert named only in string data, is a revert — core's shared rule")
  func simulationUsesSharedRevertRule() async {
    let answers: [(String, [String: Any])] = [
      ("rpc-sim-code3.rpc", ["code": 3, "message": "VM execution error."]),
      ("rpc-sim-data.rpc", ["code": -32015, "message": "VM execution error.", "data": "Reverted 0x"]),
    ]
    for (host, answer) in answers {
      let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "error": answer])
      StubURLProtocol.setHandler(host: host) { _ in body }

      let error = await #expect(throws: RainError.self) {
        _ = try await client().callForHexResult(
          rpcUrl: "https://\(host)/", method: "eth_call", params: [], purpose: .simulation)
      }
      #expect(error?.code == "RAIN_403", "code 3 or a revert in data counts, not only the message (\(answer))")
    }
  }

  @Test("simulation: revert is checked before insufficient funds")
  func simulationRevertBeatsInsufficient() async {
    let host = "rpc-sim-order.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: 3, message: "execution reverted: insufficient funds for transfer")
    }

    await #expect(throws: RainError.transactionSimulationFailed(underlying: NSError(domain: "", code: 0))) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_call", params: [], purpose: .simulation)
    }
  }

  @Test("read: insufficient funds maps to insufficientFunds")
  func readInsufficientFundsClassifies() async {
    let host = "rpc-read-funds.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: -32000, message: "insufficient funds for gas * price + value")
    }

    await #expect(throws: RainError.insufficientFunds(required: "", available: "")) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_estimateGas", params: [])
    }
  }

  @Test("read: access denied maps to internalError, not userRejected")
  func readAccessDeniedIsNotUserRejected() async {
    let host = "rpc-read-denied.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: -32000, message: "access denied")
    }

    // A node message is never a user action; the old keyword mapping misfiled this as RAIN_401.
    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_getBalance", params: [])
    }
  }

  @Test("read: a revert maps to internalError, not a simulation verdict")
  func readRevertIsInternal() async {
    let host = "rpc-read-revert.rpc"
    StubURLProtocol.setHandler(host: host) { _ in
      RpcStub.error(code: 3, message: "execution reverted")
    }

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_call", params: [])
    }
  }

  @Test("maps a non-string result to internalError")
  func nonStringResult() async {
    let host = "rpc-nonstring.rpc"
    StubURLProtocol.setHandler(host: host) { _ in RpcStub.rawResult(["unexpected": true]) }

    await #expect(throws: RainError.internalError(details: "")) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_getBalance", params: [])
    }
  }

  @Test("maps a non-JSON body to a RainError")
  func nonJsonBody() async {
    let host = "rpc-nonjson.rpc"
    StubURLProtocol.setHandler(host: host) { _ in Data("not json at all".utf8) }

    await #expect(throws: RainError.self) {
      _ = try await client().callForHexResult(
        rpcUrl: "https://\(host)/", method: "eth_getBalance", params: [])
    }
  }

  @Test("rejects an unparseable RPC url with invalidRpcUrl")
  func invalidUrl() async {
    await #expect(throws: RainError.invalidRpcUrl("")) {
      _ = try await client().callForHexResult(
        rpcUrl: "", method: "eth_getBalance", params: [])
    }
  }

  @Test("maps a transport failure to networkError")
  func transportFailure() async {
    // No handler registered for this host → the stub fails the load with a URLError.
    do {
      _ = try await client().callForHexResult(
        rpcUrl: "https://rpc-unreachable.rpc/", method: "eth_getBalance", params: [])
      Issue.record("expected an error")
    } catch let error as RainError {
      #expect(error.code == "RAIN_301")
    } catch {
      Issue.record("expected RainError, got \(error)")
    }
  }
}

final class PrivyRedirectingURLProtocol: URLProtocol {
  nonisolated(unsafe) static var plainHttpRequests = 0
  private static let lock = NSLock()

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PrivyRedirectingURLProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let url = request.url!
    if url.scheme == "https" {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      components.scheme = "http"
      let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": components.string!])!
      var next = request
      next.url = components.url
      client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
      client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    Self.lock.lock(); Self.plainHttpRequests += 1; Self.lock.unlock()
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": "0x1"]))
    client?.urlProtocolDidFinishLoading(self)
  }
}
