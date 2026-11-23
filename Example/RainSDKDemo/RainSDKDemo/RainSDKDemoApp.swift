import SwiftUI

@main
struct RainSDKDemoApp: App {
  init() {
    // One-shot vendor init from the saved ids so a restored session can be resumed.
    switch SessionStore.provider {
    case .turnkey where !SessionStore.turnkeyOrgId.isEmpty && !SessionStore.turnkeyAuthProxyConfigId.isEmpty:
      try? TurnkeyAuthSample.configure(
        organizationId: SessionStore.turnkeyOrgId,
        authProxyConfigId: SessionStore.turnkeyAuthProxyConfigId
      )
    case .privy where !SessionStore.privyAppId.isEmpty && !SessionStore.privyAppClientId.isEmpty:
      try? PrivyAuthSample.shared.initialize(
        appId: SessionStore.privyAppId,
        appClientId: SessionStore.privyAppClientId
      )
    default:
      break
    }
  }

  var body: some Scene {
    WindowGroup {
      HomeView()
    }
  }
}
