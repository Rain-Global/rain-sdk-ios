import Foundation
import Web3
import Web3
@testable import RainCore

// MARK: - Mock Transaction Builder

/// Mock transaction builder for testing nonce retrieval
final class MockTransactionBuilderService: TransactionBuilderProtocol {
  private let networkConfigs: [NetworkConfig]
  var mockNonce: BigUInt = BigUInt(123)
  /// What the `isAdmin` read answers; only `.notAdmin` blocks a withdrawal.
  var mockIsCollateralAdmin: CollateralAdminCheck = .admin
  private(set) var isCollateralAdminCallCount = 0

  init(networkConfigs: [NetworkConfig]) {
    self.networkConfigs = networkConfigs
  }
  
  func generateSalt() -> Data {
    var randomBytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
    return Data(randomBytes)
  }
  
  func getLatestNonce(proxyAddress: String, chainId: Int) async throws -> BigUInt {
    // Return mock nonce for testing
    return mockNonce
  }

  func isCollateralAdmin(
    proxyAddress: String,
    walletAddress: String,
    chainId: Int
  ) async throws -> CollateralAdminCheck {
    isCollateralAdminCallCount += 1
    return mockIsCollateralAdmin
  }
  
  func buildEIP712Message(
    chainId: Int,
    collateralProxyAddress: String,
    walletAddress: String,
    tokenAddress: String,
    amount: BigUInt,
    recipientAddress: String,
    nonce: BigUInt,
    salt: String
  ) throws -> String {
    // Match protocol: salt is already a hex string (e.g. "0x...")
    let domain: [String: Any] = [
      "name": "Collateral",
      "version": "2",
      "chainId": chainId,
      "verifyingContract": collateralProxyAddress,
      "salt": salt
    ]
    
    let types: [String: Any] = [
      "EIP712Domain": [
        ["name": "name", "type": "string"],
        ["name": "version", "type": "string"],
        ["name": "chainId", "type": "uint256"],
        ["name": "verifyingContract", "type": "address"],
        ["name": "salt", "type": "bytes32"]
      ],
      "Withdraw": [
        ["name": "user", "type": "address"],
        ["name": "asset", "type": "address"],
        ["name": "amount", "type": "uint256"],
        ["name": "recipient", "type": "address"],
        ["name": "nonce", "type": "uint256"]
      ]
    ]
    
    let message: [String: Any] = [
      "user": walletAddress,
      "asset": tokenAddress,
      "amount": amount.description,
      "recipient": recipientAddress,
      "nonce": nonce.description
    ]
    
    let messageToSign: [String: Any] = [
      "types": types,
      "domain": domain,
      "primaryType": "Withdraw",
      "message": message
    ]
    
    let jsonData = try JSONSerialization.data(
      withJSONObject: messageToSign,
      options: [.sortedKeys]
    )
    
    guard let messageString = String(data: jsonData, encoding: .utf8) else {
      throw RainError.internalError(
        details: "Failed to serialize EIP-712 message to JSON"
      )
    }
    
    return messageString
  }
  
  func buildErc20TransactionForWithdrawAsset(
    ethereumContractAddress: EthereumAddress,
    withdrawAssetParameter: WithdrawAssetParameter
  ) throws -> String {
    // Mock implementation - return dummy transaction data
    return "0x" + String(repeating: "a1b2c3d4", count: 16)
  }

  func buildERC20TransferData(
    chainId: Int,
    contractAddress: String,
    walletAddress: String,
    toAddress: String,
    amount: BigUInt
  ) async throws -> String {
    // Mock implementation - return dummy ERC-20 transfer calldata
    return "0xa9059cbb" + String(repeating: "0", count: 128)
  }

  var stubbedApproveData = "0x095ea7b3" + String(repeating: "0", count: 128)

  func buildERC20ApproveData(
    chainId: Int,
    contractAddress: String,
    walletAddress: String,
    spender: String,
    amount: BigUInt
  ) async throws -> String {
    stubbedApproveData
  }

  func encodeBalanceOfCall(walletAddress: String, chainId: Int) async throws -> String {
    // Mock balanceOf(address) calldata: selector + zero-padded address
    let selector = "70a08231"
    let cleanAddress = walletAddress.hasPrefix("0x") ? String(walletAddress.dropFirst(2)) : walletAddress
    let paddedAddress = String(repeating: "0", count: max(0, 64 - cleanAddress.count)) + cleanAddress
    return "0x" + selector + paddedAddress
  }
}
