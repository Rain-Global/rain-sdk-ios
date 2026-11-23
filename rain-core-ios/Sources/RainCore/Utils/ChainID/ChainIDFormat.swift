import Foundation

/// Chain ID format types (e.g. EIP-155: "eip155:1", Solana CAIP-2: "solana:<genesis>").
public enum ChainIDFormat: Equatable {
  case EIP155
  case solana

  /// Get the namespace prefix for the format
  public var prefix: String {
    switch self {
    case .EIP155:
      return "eip155"
    case .solana:
      return "solana"
    }
  }

  /// The format that addresses `chainId`: `.solana` for Rain's Solana chain IDs (900–902),
  /// `.EIP155` for everything else. Call sites use this instead of hardcoding `.EIP155`.
  public static func namespace(for chainId: Int) -> ChainIDFormat {
    SolanaChains.isSolana(chainId) ? .solana : .EIP155
  }

  /// Format a chain ID as a string in this format
  /// - Parameter chainId: The chain ID as an integer (an EVM chain ID, or a Solana sentinel)
  /// - Returns: Formatted string (e.g., "eip155:1" or "solana:<genesis>")
  public func format(chainId: Int) -> String {
    switch self {
    case .EIP155:
      return "\(prefix):\(chainId)"
    case .solana:
      // The Solana sentinel int is not part of the CAIP-2 string; resolve via the cluster map.
      return SolanaChains.caip2(for: chainId) ?? "\(prefix):\(chainId)"
    }
  }

  /// Parse a formatted string to extract the chain ID
  /// - Parameter string: Formatted string (e.g., "eip155:1" or "solana:<genesis>")
  /// - Returns: The chain ID as an integer, or nil if format is invalid
  public func parse(_ string: String) -> Int? {
    switch self {
    case .EIP155:
      let components = string.components(separatedBy: ":")
      guard components.count == 2,
            components[0] == prefix,
            let chainId = Int(components[1]) else {
        return nil
      }
      return chainId
    case .solana:
      return SolanaChains.chainId(forCaip2: string)
    }
  }

  /// Check if a string is valid for this format
  /// - Parameter string: String to validate
  /// - Returns: true if the string matches this format
  func isValid(_ string: String) -> Bool {
    return parse(string) != nil
  }
}
