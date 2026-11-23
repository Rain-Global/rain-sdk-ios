import Foundation

/// Trusted Auth Pull targets for one Rain environment: per chain, the token contract an approval
/// may name.
///
/// Auth Pull approvals are intentionally disabled until a host supplies this configuration. The
/// SDK then requires every approval, allowance read, confirmation, and fee estimate to use the
/// configured token for the selected chain. The spender is not configured: it is the user's
/// collateral contract, passed on each call.
public struct RainAuthPullConfig: Sendable, Equatable {
  /// The trusted token contract per Auth Pull chain: the only token an approval may target.
  public let tokenAddresses: [Int: String]

  /// Which environment this configuration is for; its chains are checked against that
  /// environment's Auth Pull set at `build()`.
  internal let kind: Kind

  internal enum Kind: Sendable { case sandbox, production, custom }

  private init(tokenAddresses: [Int: String], kind: Kind) {
    self.tokenAddresses = tokenAddresses
    self.kind = kind
  }

  /// Canonical sandbox USDC contracts.
  public static func sandbox() -> RainAuthPullConfig {
    RainAuthPullConfig(
      tokenAddresses: [
        RainChain.baseSepolia: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        RainChain.arbitrumSepolia: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
      ],
      kind: .sandbox
    )
  }

  /// Canonical production USDC contracts.
  public static func production() -> RainAuthPullConfig {
    RainAuthPullConfig(
      tokenAddresses: [
        RainChain.baseMainnet: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        RainChain.arbitrumMainnet: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
      ],
      kind: .production
    )
  }

  /// Explicit targets for a non-standard Rain deployment (staging, a self-hosted gateway). Its
  /// chains may come from either environment's Auth Pull set; the token map must be exact.
  public static func custom(tokenAddresses: [Int: String]) -> RainAuthPullConfig {
    RainAuthPullConfig(tokenAddresses: tokenAddresses, kind: .custom)
  }
}
