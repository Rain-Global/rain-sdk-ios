import Foundation

/// Intercepts `URLSession.shared` requests so tests can stub JSON-RPC responses
/// for the Turnkey adapter (which calls `URLSession.shared` directly for `eth_*` RPC).
///
/// Only matches requests to hosts in `interceptedHosts` (default: the local test fixture host),
/// so concurrent tests hitting other URLs (e.g. live Fuji RPC) pass through unaffected.
/// Tests using this protocol should run serialized — see `.serialized` on the suite.
///
/// Usage:
///   await MockURLProtocol.install()
///   defer { MockURLProtocol.reset() }
///   MockURLProtocol.stub(method: "eth_gasPrice", result: "0x4a817c800")
final class MockURLProtocol: URLProtocol {
  /// Default hosts intercepted by EVM tests. `reset()` restores this so a test that points
  /// `interceptedHosts` at a different host (e.g. a Solana RPC) can't leak that into the next
  /// suite and send its requests to the real network.
  nonisolated(unsafe) static let defaultInterceptedHosts: Set<String> = ["mainnet.infura.io"]
  /// Hosts this protocol will intercept. Other hosts pass through to the real network.
  nonisolated(unsafe) static var interceptedHosts: Set<String> = MockURLProtocol.defaultInterceptedHosts
  /// Maps JSON-RPC method name → stubbed `result` payload (any JSON-serializable value).
  nonisolated(unsafe) private static var stubs: [String: Any] = [:]
  /// Maps JSON-RPC method name → error to throw instead of returning a response.
  nonisolated(unsafe) private static var errors: [String: Error] = [:]
  /// Recorded JSON-RPC method names in call order.
  nonisolated(unsafe) private(set) static var recordedMethods: [String] = []
  /// Process-wide gate so suites sharing the global `URLProtocol` registration don't trample
  /// each other's stubs when Swift Testing runs suites in parallel. Suspends, never blocks.
  private static let serialGate = AsyncGate()

  static func install() async {
    await serialGate.acquire()
    URLProtocol.registerClass(MockURLProtocol.self)
  }

  static func reset() {
    URLProtocol.unregisterClass(MockURLProtocol.self)
    stubs.removeAll()
    errors.removeAll()
    recordedMethods.removeAll()
    interceptedHosts = defaultInterceptedHosts
    serialGate.release()
  }

  /// Idiomatic scope helper — guarantees `reset()` runs even if the body throws, so
  /// a test failure inside the block doesn't strand the semaphore and deadlock the
  /// next installer. Prefer this over manual `install() / defer { reset() }`.
  static func withInstalled<T>(_ body: () async throws -> T) async rethrows -> T {
    await install()
    defer { reset() }
    return try await body()
  }

  static func stub(method: String, result: Any) {
    stubs[method] = result
    errors.removeValue(forKey: method)
  }

  static func stubError(method: String, error: Error) {
    errors[method] = error
    stubs.removeValue(forKey: method)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    guard let host = request.url?.host else { return false }
    return interceptedHosts.contains(host)
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let method = parseRPCMethod(from: request)
    if let method {
      MockURLProtocol.recordedMethods.append(method)
    }

    if let method, let error = MockURLProtocol.errors[method] {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }

    let resultValue: Any
    if let method, let stub = MockURLProtocol.stubs[method] {
      resultValue = stub
    } else {
      // Default fallback: zero hex string. Tests should stub explicitly for clarity.
      resultValue = "0x0"
    }

    let response: [String: Any] = [
      "jsonrpc": "2.0",
      "id": 1,
      "result": resultValue
    ]
    let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    let httpResponse = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  private func parseRPCMethod(from request: URLRequest) -> String? {
    guard let body = request.httpBody ?? request.httpBodyStream.flatMap(readStream) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return json["method"] as? String
  }

  private func readStream(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
