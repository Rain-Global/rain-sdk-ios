import Foundation

/// Network configuration for Rain wallet providers.
public struct NetworkConfig: Sendable {
  /// The network/chain identifier as an integer (EIP-155 chain ID)
  /// Examples: 1 (Ethereum Mainnet), 137 (Polygon), 42161 (Arbitrum)
  public let chainId: Int
  
  /// The RPC endpoint URL for the network
  public let rpcUrl: String
  
  /// Optional network name for display purposes
  public let networkName: String?
  
  /// CAIP-2 chain ID: "eip155:<id>" for EVM chains, "solana:<genesis>" for Solana sentinels.
  public var eip155ChainId: String {
    return ChainIDFormat.namespace(for: chainId).format(chainId: chainId)
  }
  
  /// Initialize network configuration with integer chain ID
  /// - Parameters:
  ///   - chainId: The chain identifier as an integer (EIP-155 format)
  ///   - rpcUrl: The RPC endpoint URL
  ///   - networkName: Optional network name
  ///   - customParams: Optional custom parameters
  public init(
    chainId: Int,
    rpcUrl: String,
    networkName: String? = nil
  ) {
    self.chainId = chainId
    self.rpcUrl = rpcUrl
    self.networkName = networkName
  }
  
  /// Initialize network configuration with EIP-155 formatted chain ID string
  /// - Parameters:
  ///   - eip155ChainId: The chain identifier in EIP-155 format (e.g., "eip155:1", "eip155:137")
  ///   - rpcUrl: The RPC endpoint URL
  ///   - networkName: Optional network name
  ///   - customParams: Optional custom parameters
  /// - Throws: `RainError.invalidConfig` if the eip155ChainId format is invalid
  public init(
    eip155ChainId: String,
    rpcUrl: String,
    networkName: String? = nil
  ) throws {
    guard let chainIdInt = ChainIDFormat.EIP155.parse(eip155ChainId) else {
      throw RainError.invalidConfig(
        details: "Invalid EIP-155 chain ID format: \(eip155ChainId). Expected 'eip155:<chainId>'"
      )
    }

    self.chainId = chainIdInt
    self.rpcUrl = rpcUrl
    self.networkName = networkName
  }
}

extension NetworkConfig: Equatable {
  public static func == (lhs: NetworkConfig, rhs: NetworkConfig) -> Bool {
    return lhs.chainId == rhs.chainId &&
    lhs.rpcUrl == rhs.rpcUrl &&
    lhs.networkName == rhs.networkName
  }
}
