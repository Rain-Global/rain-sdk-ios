import Foundation

/// Identifies a token to read a balance for, independent of any specific chain family.
///
/// `.native` is the chain's own currency (e.g. ETH, AVAX, POL); `.contract` is a token
/// identified by its on-chain contract address. Contract-address equality is
/// case-insensitive, so callers may pass checksummed or lowercased addresses
/// interchangeably.
public enum Token: Sendable {
  case native
  case contract(address: String)

  /// The contract address lowercased for stable comparison / lookup, or `nil` for `.native`.
  public var normalizedAddress: String? {
    switch self {
    case .native: return nil
    case .contract(let address): return address.lowercased()
    }
  }
}

extension Token: Equatable, Hashable {
  public static func == (lhs: Token, rhs: Token) -> Bool {
    switch (lhs, rhs) {
    case (.native, .native):
      return true
    case let (.contract(lhsAddress), .contract(rhsAddress)):
      return lhsAddress.lowercased() == rhsAddress.lowercased()
    default:
      return false
    }
  }

  public func hash(into hasher: inout Hasher) {
    switch self {
    case .native:
      hasher.combine(0)
    case .contract(let address):
      hasher.combine(1)
      hasher.combine(address.lowercased())
    }
  }
}
