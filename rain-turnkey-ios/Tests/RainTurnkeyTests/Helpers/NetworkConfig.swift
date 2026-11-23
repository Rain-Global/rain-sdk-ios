@testable import RainCore
@testable import RainTurnkey

// MARK: - Test Helpers

extension NetworkConfig {
  /// Helper to create test network configs
  static func testConfig(chainId: Int, rpcUrl: String = "https://test-rpc.com") -> NetworkConfig {
    NetworkConfig(chainId: chainId, rpcUrl: rpcUrl)
  }
}
