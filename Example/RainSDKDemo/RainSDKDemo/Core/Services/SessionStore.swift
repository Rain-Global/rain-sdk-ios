import Foundation
import Security

/// Keychain copy of the last working credentials, read once at launch to resume the session.
enum SessionStore {
  enum Provider: String { case portal, turnkey, privy, rainWallet }

  private static let service = Bundle.main.bundleIdentifier ?? "com.rain.sdk"
  private static let allKeys = [
    "provider", "rainApiKey", "rainUserId", "portalSessionToken",
    "turnkeyOrgId", "turnkeyAuthProxyConfigId", "turnkeyEmail",
    "privyAppId", "privyAppClientId", "privyEmail",
  ]

  static var provider: Provider? {
    get { read("provider").flatMap(Provider.init(rawValue:)) }
    set { write("provider", newValue?.rawValue) }
  }
  static var rainApiKey: String { get { read("rainApiKey") ?? "" } set { write("rainApiKey", newValue) } }
  static var rainUserId: String { get { read("rainUserId") ?? "" } set { write("rainUserId", newValue) } }
  static var portalSessionToken: String {
    get { read("portalSessionToken") ?? "" } set { write("portalSessionToken", newValue) }
  }
  static var turnkeyOrgId: String { get { read("turnkeyOrgId") ?? "" } set { write("turnkeyOrgId", newValue) } }
  static var turnkeyAuthProxyConfigId: String {
    get { read("turnkeyAuthProxyConfigId") ?? "" } set { write("turnkeyAuthProxyConfigId", newValue) }
  }
  static var turnkeyEmail: String { get { read("turnkeyEmail") ?? "" } set { write("turnkeyEmail", newValue) } }
  static var privyAppId: String { get { read("privyAppId") ?? "" } set { write("privyAppId", newValue) } }
  static var privyAppClientId: String {
    get { read("privyAppClientId") ?? "" } set { write("privyAppClientId", newValue) }
  }
  static var privyEmail: String { get { read("privyEmail") ?? "" } set { write("privyEmail", newValue) } }
  /// The last login contact used with the Rain wallet — an email address or a phone number.
  static var rainWalletContact: String { get { read("rainWalletContact") ?? "" } set { write("rainWalletContact", newValue) } }

  static func clear() {
    allKeys.forEach { write($0, nil) }
  }

  private static func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  // Any Keychain failure reads as "not stored", so a broken store behaves like a first run.
  private static func read(_ key: String) -> String? {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func write(_ key: String, _ value: String?) {
    SecItemDelete(baseQuery(key) as CFDictionary)
    guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
    var query = baseQuery(key)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    if status != errSecSuccess { SampleLog.w("SessionStore", "write \(key) failed: \(status)") }
  }
}
