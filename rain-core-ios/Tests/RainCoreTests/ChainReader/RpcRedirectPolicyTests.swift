import Foundation
import Testing
@_spi(RainAdapter) @testable import RainCore

@Suite(.serialized)
struct RpcRedirectPolicyTests {
  private func redirect(from: String, to: String) async -> URLRequest? {
    let task = URLSession.shared.dataTask(with: URL(string: from)!)
    let response = HTTPURLResponse(url: URL(string: from)!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    return await RpcRedirectPolicy.shared.urlSession(
      .shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: to)!)
    )
  }

  @Test func refusesARedirectBetweenHttpsAndHttp() async {
    #expect(await redirect(from: "https://rpc.test", to: "http://rpc.test") == nil)
    #expect(await redirect(from: "http://localhost:8545", to: "https://rpc.test") == nil)
  }

  @Test func followsARedirectThatKeepsTheScheme() async {
    #expect(await redirect(from: "https://rpc.test", to: "https://rpc2.test")?.url?.absoluteString == "https://rpc2.test")
  }

  @Test func jsonRpcClientRefusesARedirectToHttp() async throws {
    RedirectingURLProtocol.plainHttpRequests = 0
    let error = await #expect(throws: RainError.self) {
      _ = try await JsonRpcClient(session: RedirectingURLProtocol.makeSession())
        .callForHexResult(rpcUrl: "https://rpc.test/v3/secret-key", method: "eth_chainId", params: [])
    }
    #expect(error?.code == "RAIN_301")
    #expect(error?.localizedDescription.contains("secret-key") == false)
    #expect(RedirectingURLProtocol.plainHttpRequests == 0)
  }
}

final class RedirectingURLProtocol: URLProtocol {
  nonisolated(unsafe) static var plainHttpRequests = 0
  private static let lock = NSLock()

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RedirectingURLProtocol.self]
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
