import Foundation
@testable import PortalSwift
@testable import RainCore
@testable import RainPortal

// MARK: - Mock Portal

/// Mock Portal class for testing that conforms to PortalRequestProtocol
/// This allows us to use it in place of Portal for unit testing
final class MockPortal: PortalRequestProtocol {
  // Mock addresses dictionary
  var mockAddresses: [PortalNamespace: String] = [:]
  
  // Mock responses for request method - store result values
  var mockResponses: [String: Any] = [:]
  var mockErrors: [String: Error] = [:]
  
  // Track request calls for verification
  var requestCalls: [(chainId: String, method: PortalRequestMethod, params: [Any])] = []

  /// Mock result for getAssets. Set in tests to simulate assets response (e.g. tokenBalances).
  /// When nil, getAssets returns an empty response (tokenBalances: nil).
  var mockAssetsResponse: AssetsResponse?

  /// Mock result for getTransactions. Returned as-is when getTransactions is called.
  var mockFetchedTransactions: [FetchedTransaction] = []

  /// When set, `addresses` throws it (e.g. an expired-session `PortalRequestsError.unauthorized`).
  var addressesError: Error?

  init() {
    // Set default mock address
    mockAddresses[PortalNamespace.eip155] = "0x1234567890123456789012345678901234567890"
  }
  
  /// Mock addresses property that matches PortalRequestProtocol
  var addresses: [PortalNamespace: String?] {
    get async throws {
      if let addressesError { throw addressesError }
      var result: [PortalNamespace: String?] = [:]
      for (key, value) in mockAddresses {
        result[key] = value
      }
      return result
    }
  }
  
  /// Mock request method that matches PortalRequestProtocol
  /// 
  /// IMPORTANT: Since PortalProviderResult cannot be initialized directly,
  /// we need to check PortalSwift's API to see how to create instances.
  /// For now, this will throw an error indicating the limitation.
  func request(
    chainId: String,
    method: PortalRequestMethod,
    params: [Any],
    options: RequestOptions?
  ) async throws -> PortalProviderResult {
    // Track the call
    requestCalls.append((chainId: chainId, method: method, params: params))
    
    // Check for configured error
    let key = "\(chainId)_\(method)"
    if let error = mockErrors[key] {
      throw error
    }
    
    // Get result value (either from mock or default)
    let resultValue: Any?
    if let mockResult = mockResponses[key] {
      resultValue = mockResult
    } else {
      // Default mock responses based on method
      switch method {
      case .eth_signTypedData_v4:
        // Return a mock signature (65 bytes = 130 hex chars)
        resultValue = "0x" + String(repeating: "1", count: 130)
      case .eth_sendTransaction:
        // Return a mock transaction hash
        resultValue = "0x" + String(repeating: "a", count: 64)
      case .eth_getBalance:
        // Return wei as decimal string (1e18 = 1 ETH) so the adapter's exact BigUInt/Decimal parse yields 1.0
        resultValue = PortalProviderRpcResponse(jsonrpc: "json", result: "1000000000000000000")
      default:
        resultValue = nil
      }
    }
    
    // Create PortalProviderResult using @testable import to access internal initializer
    // With @testable import PortalSwift, we should have access to internal members
    let portalResult = PortalProviderResult(
      id: UUID().uuidString,
      result: resultValue ?? NSNull()
    )
    
    return portalResult
  }

  func getAssets(_ chainId: String) async throws -> AssetsResponse {
    return mockAssetsResponse ?? AssetsResponse(nativeBalance: nil, tokenBalances: nil, nfts: nil)
  }

  func getTransactions(
    _ chainId: String,
    limit: Int?,
    offset: Int?,
    order: TransactionOrder?
  ) async throws -> [FetchedTransaction] {
    return mockFetchedTransactions
  }

  /// Helper to set mock response for a specific chainId and method
  func setMockResponse(
    chainId: String,
    method: PortalRequestMethod,
    result: Any? = nil,
    error: Error? = nil
  ) {
    let key = "\(chainId)_\(method)"
    if let error = error {
      mockErrors[key] = error
      mockResponses.removeValue(forKey: key)
    } else {
      mockResponses[key] = result
      mockErrors.removeValue(forKey: key)
    }
  }
  
  /// Stubs the RPC pair the adapter uses to resolve a UserOperation hash: a block number to scan
  /// from, and the EntryPoint log the operation was emitted in.
  func stubUserOperation(chainId: Int, transactionHash: String, succeeded: Bool) {
    let chainIdString = "eip155:\(chainId)"
    setMockResponse(
      chainId: chainIdString,
      method: .eth_blockNumber,
      result: PortalProviderRpcResponse(jsonrpc: "2.0", result: "0x10")
    )
    // UserOperationEvent data: nonce, success, actualGasCost, actualGasUsed.
    let zeroWord = String(repeating: "0", count: 64)
    let successWord = String(repeating: "0", count: 63) + (succeeded ? "1" : "0")
    setMockResponse(
      chainId: chainIdString,
      method: .eth_getLogs,
      result: LogsResponse(
        result: [
          Log(
            transactionHash: transactionHash,
            address: nil,
            blockHash: nil,
            blockNumber: nil,
            data: "0x" + zeroWord + successWord + zeroWord + zeroWord,
            logIndex: nil,
            removed: nil,
            topics: nil,
            transactionIndex: nil
          )
        ]
      )
    )
  }

  /// Helper to set mock address
  func setMockAddress(_ address: String, forNamespace namespace: PortalNamespace = PortalNamespace.eip155) {
    mockAddresses[namespace] = address
  }
  
  /// Reset all mocks
  func reset() {
    mockAddresses = [PortalNamespace.eip155: "0x1234567890123456789012345678901234567890"]
    mockResponses = [:]
    mockErrors = [:]
    mockAssetsResponse = nil
    mockFetchedTransactions = []
    addressesError = nil
    requestCalls = []
  }
}
