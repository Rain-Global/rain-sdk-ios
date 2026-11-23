import Foundation

/// The chains Rain's Auth Pull runs on, grouped by environment.
///
/// Rain's USDC contract differs between sandbox and production, and the two sets of chains do not
/// overlap. Approving on a chain from the wrong environment therefore produces a perfectly valid
/// allowance that no authorization will ever draw on — and on a mainnet chain it spends real gas
/// to grant that allowance.
/// The approval path rejects that pairing up front (see `RainSdkManager+Approvals`).
///
/// This answers for an *environment*. What a built SDK will actually accept is narrower — the
/// host's ``RainAuthPullConfig`` intersected with the chains that have an RPC endpoint — and is
/// exposed as ``RainSdk/authPullChainIds`` / ``RainClient/authPullChainIds``. Gate UI on those;
/// reach for the static sets only before an SDK exists, and never keep a third copy of the list,
/// which is how these drift apart.
///
/// **Maintenance**
/// In-tree like `TokenRegistry`, so the SDK owns updates. Rain is actively adding chains to the
/// beta; edit this file and ship a release. The matching USDC entries live in `TokenRegistry`, and
/// `RainAuthPullChainsTests` enforces that every chain here has one.
public enum RainAuthPullChains {
  /// Sandbox Auth Pull chains.
  public static let sandbox: Set<Int> = [
    RainChain.baseSepolia,
    RainChain.arbitrumSepolia,
  ]

  /// Production Auth Pull chains.
  public static let production: Set<Int> = [
    RainChain.baseMainnet,
    RainChain.arbitrumMainnet,
  ]

  /// The Auth Pull chains a configuration of `kind` may target. A custom configuration can front
  /// either environment, so it is allowed both known sets.
  internal static func supported(for kind: RainAuthPullConfig.Kind) -> Set<Int> {
    switch kind {
    case .sandbox: return sandbox
    case .production: return production
    case .custom: return sandbox.union(production)
    }
  }
}
