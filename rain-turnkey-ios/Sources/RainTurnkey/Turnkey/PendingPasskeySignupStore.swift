import Foundation

// MARK: - Why this exists
//
// `/signup/passkey` can time out or fail with a 5xx AFTER rain-api has started creating the
// account — and rain-api keeps going past our timeout. If the SDK simply dropped the passkey it
// just registered, the next tap would register a second one and create a second account, while
// the first passkey still signs straight into the first account through Turnkey — an account
// rain-api never recorded. Balances and transaction webhooks for its addresses are dropped, it is
// missing from the tenant dashboard, and nothing built on Rain's wallet list can see it. No keys
// are lost, but the wallet sits outside the system.
//
// rain-api recovers such an account only when the SAME passkey is sent to `/signup/passkey`
// again (it finds the account by credential id and records it). So on an unknown outcome the
// SDK keeps the registration, persisted across launches, and the next `signUpWithPasskey`
// resends it instead of running a new ceremony. See `TurnkeyManagedAuthController`.

/// Where an unfinished passkey signup's registration waits between attempts.
internal protocol PendingPasskeySignupStore: Sendable {
  func load() -> PasskeyRegistration?
  func save(_ registration: PasskeyRegistration)
  func clear()
}

/// Persists across launches in `UserDefaults`. The payload is the WebAuthn attestation —
/// public material by design (it is what the server receives) — plus the challenge; nothing
/// secret, so defaults are an appropriate home.
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but not marked `Sendable`.
internal struct UserDefaultsPendingPasskeySignupStore: PendingPasskeySignupStore, @unchecked Sendable {
  static let key = "com.rain.sdk.rainwallet.pendingPasskeySignup"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> PasskeyRegistration? {
    guard let data = defaults.data(forKey: Self.key) else { return nil }
    return try? JSONDecoder().decode(PasskeyRegistration.self, from: data)
  }

  func save(_ registration: PasskeyRegistration) {
    guard let data = try? JSONEncoder().encode(registration) else { return }
    defaults.set(data, forKey: Self.key)
  }

  func clear() {
    defaults.removeObject(forKey: Self.key)
  }
}
