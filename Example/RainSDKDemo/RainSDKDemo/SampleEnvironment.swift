import Foundation
import RainCore

/// Which Rain environment this build of the demo talks to.
///
/// One constant drives three things that have to agree: the Rain API host the demo's own
/// `RainApiClient` calls, the chains the picker offers, and the Auth Pull configuration the SDK is
/// built with. The SDK itself knows nothing about Rain environments — it only checks that an Auth
/// Pull config's chains belong to the environment its kind names.
///
/// Left on `.sandbox` deliberately. `.production` means mainnet: real USDC, real gas, and an
/// allowance a real card authorization can draw on.
enum SampleEnvironment {
  static let rainApi: RainApiEnvironment = .sandbox

  /// The trusted targets the SDK is built with. Auth Pull is refused entirely without this, and
  /// then accepts only the canonical token for each chain.
  static var authPullConfig: RainAuthPullConfig {
    isProduction ? .production() : .sandbox()
  }

  static var isProduction: Bool { rainApi == .production }

  /// The Auth Pull chains for this environment — the picker's answer before any SDK exists.
  static var authPullChains: Set<Int> {
    isProduction ? RainAuthPullChains.production : RainAuthPullChains.sandbox
  }

  /// A human label for the mode banner, so it is obvious which environment a build is pointed at.
  static var displayName: String {
    isProduction ? "Production" : "Sandbox"
  }
}
