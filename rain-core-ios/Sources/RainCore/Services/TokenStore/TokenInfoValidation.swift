import Foundation
import Web3

/// Checks shared by every token-registration and token-lookup entry point. A cross-platform
/// contract with the Android SDK's `TokenInfoValidation`.
internal enum TokenInfoValidation {
  /// Decimals no money path can scale by fall outside this range: `10^78` overflows a `uint256`.
  static let decimalsRange = 0...77

  /// Rejects a malformed token address at the source — an entry that enters the store rides into
  /// every balance batch on its chain. EVM: `0x` + 40 hex characters, and a correct EIP-55
  /// checksum when mixed-case (all-lowercase / all-uppercase carry none); the prefix is required
  /// because the store keys entries by the string as given, so a bare or `0X` spelling would never
  /// match its `0x` twin. Solana: base58 decoding to 32 bytes.
  static func requireValidAddress(chainId: Int, address: String) throws {
    if SolanaChains.isSolana(chainId) {
      guard let bytes = try? Base58.decode(address), bytes.count == 32 else {
        throw RainError.invalidConfig(details: "Invalid token mint for chainId=\(chainId): \(address)")
      }
    } else {
      guard address.hasPrefix("0x") else {
        throw RainError.invalidConfig(
          details: "Invalid token address for chainId=\(chainId): expected a 0x prefix: \(address)"
        )
      }
      guard EthereumAddress.parse(address) != nil else {
        throw RainError.invalidConfig(
          details: "Invalid token address for chainId=\(chainId): \(address) (malformed or bad EIP-55 checksum)"
        )
      }
    }
  }

  /// Validates a whole registration list before anything is stored, so one bad entry registers
  /// nothing: addresses per `requireValidAddress`, `decimals` within `decimalsRange`.
  static func requireValid(_ tokens: [TokenInfo]) throws {
    for token in tokens {
      try requireValidAddress(chainId: token.chainId, address: token.address)
      guard decimalsRange.contains(token.decimals) else {
        throw RainError.invalidConfig(
          details: "Invalid token decimals for chainId=\(token.chainId) \(token.address): "
            + "\(token.decimals), expected \(decimalsRange.lowerBound)...\(decimalsRange.upperBound)"
        )
      }
    }
  }

  /// Rejects an on-chain `decimals()` answer no money path can scale by.
  static func requireValidChainDecimals(_ decimals: Int, chainId: Int, address: String) throws {
    guard decimalsRange.contains(decimals) else {
      throw RainError.invalidConfig(
        details: "Token \(address) on chainId=\(chainId) reports decimals=\(decimals), "
          + "outside \(decimalsRange.lowerBound)...\(decimalsRange.upperBound)"
      )
    }
  }
}
