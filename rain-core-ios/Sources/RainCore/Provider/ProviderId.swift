import Foundation

/// Stable identifier for a wallet provider. Open (wraps a `String`) rather than a closed enum so
/// host apps can register their own providers with custom ids.
public struct ProviderId: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ value: String) {
    self.rawValue = value
  }

  public var value: String { rawValue }
  public var description: String { rawValue }

  /// Portal MPC adapter (shipped in the `RainPortal` module).
  public static let portal = ProviderId("portal")
  /// Turnkey P256-stamp adapter (bundled inside `RainCore` for now).
  public static let turnkey = ProviderId("turnkey")
  /// Privy embedded-key adapter (shipped in the `RainPrivy` module).
  public static let privy = ProviderId("privy")
  /// Rain-branded wallet (shipped in the `RainWallet` module).
  public static let rain = ProviderId("rain")
}
