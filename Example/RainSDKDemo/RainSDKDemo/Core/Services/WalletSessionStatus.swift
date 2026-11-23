import Foundation
import RainCore
import RainPortal
import RainPrivy
import RainTurnkey
import RainWallet

/// Coarse health of the wallet session, for colouring the home screen's session card.
enum SessionHealth {
  case healthy
  case transitional
  case dead
  case unknown
}

/// Provider-agnostic view of the wallet session; each provider's state type maps to it below.
struct WalletSessionStatus: Equatable {
  let label: String
  let health: SessionHealth
  let detail: String?

  init(_ label: String, _ health: SessionHealth, detail: String? = nil) {
    self.label = label
    self.health = health
    self.detail = detail
  }
}

extension TurnkeySessionState {
  /// Turnkey: JWT-backed, so `.active` carries an expiry.
  var status: WalletSessionStatus {
    switch self {
    case .loading:
      return WalletSessionStatus("Restoring session", .transitional)
    case .active(let expiresAt):
      return WalletSessionStatus(
        "Active", .healthy,
        detail: "JWT expires at \(Self.clock(expiresAt)) (auto-refreshed by the SDK)"
      )
    case .expired:
      return WalletSessionStatus("Expired", .dead, detail: "Log in again")
    case .unauthenticated:
      return WalletSessionStatus("Unauthenticated", .dead, detail: "Log in again")
    }
  }

  private static let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static func clock(_ epochSeconds: TimeInterval) -> String {
    clockFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
  }
}

extension PrivySessionState {
  /// Privy: self-refreshing with no expiry; `.unverified` = restored offline, recoverable.
  var status: WalletSessionStatus {
    switch self {
    case .loading:
      return WalletSessionStatus("Restoring session", .transitional)
    case .active:
      return WalletSessionStatus("Active", .healthy, detail: "Privy refreshes the session itself")
    case .unverified:
      return WalletSessionStatus(
        "Unverified", .transitional,
        detail: "Restored offline; re-verified when connectivity returns"
      )
    case .unauthenticated:
      return WalletSessionStatus("Unauthenticated", .dead, detail: "Log in again")
    }
  }
}

extension PortalSessionState {
  /// Portal: derived from call outcomes — the vendor exposes no auth state.
  var status: WalletSessionStatus {
    switch self {
    case .unknown:
      return WalletSessionStatus("Unknown", .unknown, detail: "No Portal call has completed yet")
    case .active:
      return WalletSessionStatus("Active", .healthy, detail: "Last Portal call succeeded")
    case .refreshing:
      return WalletSessionStatus("Refreshing", .transitional, detail: "Installing a re-minted session token")
    case .expired:
      return WalletSessionStatus(
        "Expired", .dead,
        detail: "Portal rejected the session token; provide a new one"
      )
    }
  }
}

extension RainWalletSessionState {
  /// Rain wallet: session-backed, so `.active` carries an expiry.
  var status: WalletSessionStatus {
    switch self {
    case .loading:
      return WalletSessionStatus("Restoring session", .transitional)
    case .active(let expiresAt):
      return WalletSessionStatus(
        "Active", .healthy,
        detail: "Session expires at \(Self.clock(expiresAt)) (auto-refreshed by the SDK)"
      )
    case .expired:
      return WalletSessionStatus("Expired", .dead, detail: "Log in again")
    case .unauthenticated:
      return WalletSessionStatus("Unauthenticated", .dead, detail: "Log in again")
    }
  }

  private static let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static func clock(_ epochSeconds: TimeInterval) -> String {
    clockFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
  }
}
