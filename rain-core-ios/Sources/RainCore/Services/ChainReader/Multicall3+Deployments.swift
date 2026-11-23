import Foundation

extension Multicall3 {
  /// zkSync Era derives contract addresses differently, so the canonical CREATE2 address does not
  /// exist there; the project ships a separate deployment.
  static let zkSyncEraAddress = "0xF9cda624FBC7e059355ce98a31693d299FACd963"

  /// Multicall3 address per Rain chain ID (https://www.multicall3.com/deployments).
  /// Used to batch read native + ERC-20 balances.
  static let deployments: [Int: String] = [
    1: canonicalAddress,        // Ethereum
    10: canonicalAddress,       // Optimism
    56: canonicalAddress,       // BNB Chain
    137: canonicalAddress,      // Polygon
    143: canonicalAddress,      // Monad
    324: zkSyncEraAddress,      // zkSync Era
    8453: canonicalAddress,     // Base
    9745: canonicalAddress,     // Plasma
    42161: canonicalAddress,    // Arbitrum
    42220: canonicalAddress,    // Celo
    43114: canonicalAddress,    // Avalanche
    57073: canonicalAddress,    // Ink
    84532: canonicalAddress,    // Base Sepolia
    421614: canonicalAddress,   // Arbitrum Sepolia
  ]

  /// Chain IDs with a known Multicall3 deployment.
  static var deployedChainIds: Set<Int> { Set(deployments.keys) }

  /// The Multicall3 address on `chainId`, or `nil` where no deployment is known.
  static func address(on chainId: Int) -> String? {
    deployments[chainId]
  }
}
