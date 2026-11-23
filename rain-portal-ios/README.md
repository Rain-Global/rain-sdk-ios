# RainPortal

The [Portal](https://portalhq.io) MPC adapter for the modular Rain iOS SDK.

Depends on `RainCore` + `PortalSwift`. Linking `RainPortal` is all a Portal-only app needs —
`RainCore` comes transitively, and Turnkey's / Privy's vendor SDKs never enter the dependency graph.

```swift
import RainPortal   // re-exports RainCore

let rain = try RainSdk.builder()
    .rpcEndpoints([43114: "https://avalanche-c-chain-rpc.publicnode.com"])
    .register(PortalProvider(PortalConfig(sessionToken: "<your-portal-session-token>")))
    .build()

let client = try await rain.provider(.portal)
```

This module owns everything Portal-specific: the `PortalProvider` descriptor, the
`PortalWalletProviderAdapter` (mapping Portal onto `WalletProvider`), Portal ↔ Rain model
mappers, and Portal error mapping (registered with `RainCore` at runtime so core stays Portal-free).

Advertised capabilities: `.export`, `.recovery`.

## Session expiry and retry

PortalSwift exposes no auth state, no token expiry, and no way to swap the token on a live client,
so Rain hardens it reactively: every call classifies auth failures, a rejected token is refreshed
by asking the host to re-mint one and rebuilding the vendor client around it, and transient
failures on reads are retried with backoff. Controlled by `PortalSessionPolicy`:

```swift
PortalProvider(
  PortalConfig(
    sessionToken: sessionToken,
    sessionPolicy: PortalSessionPolicy(
      autoRefresh: true,        // re-mint + retry once on a rejected token
      maxTransientRetries: 2    // backoff retries for 5xx/429/408/network on reads
    ),
    onSessionTokenNeeded: {
      // Portal rejected the current token: return a freshly minted token for the SAME
      // Portal client, or nil to decline. Do not call back into the provider from here.
      try await backend.mintPortalSessionToken(userId)
    },
    onSessionExpired: {
      // No fresh token could be installed. Fired once per session death; route to login.
    }
  )
)
```

- **Auth classification** — `PortalRequestsError.unauthorized` / MPC `INVALID_API_KEY` at any
  call site surfaces as `RainError.tokenExpired`.
- **Refresh** — the SDK asks `onSessionTokenNeeded` for a token, rebuilds the vendor `Portal`
  with the same RPC config, re-fires `onPortalCreated`, and retries the call once (safe for
  sends: Portal rejects a bad token before executing). Refreshes are single-flighted. Device MPC
  shares are keyed by Portal client id, not token, so the rebuild keeps signing with the same
  share — the re-minted token **must belong to the same Portal client**.
- **Pre-call guard** — a token known to be dead is re-minted first or fails fast.
- **Transient backoff** — reads retry HTTP 5xx/429/408 and network failures with exponential
  backoff; sends and signing never retry on transient failures.
- **Re-auth hook** — when no fresh token can be installed, the call throws
  `RainError.tokenExpired` and `onSessionExpired` fires once; it re-arms after a successful
  refresh.

Observing: `provider.sessionState` (`AnyPublisher<PortalSessionState, Never>`) and
`provider.currentSessionState()` report `.unknown / .active / .refreshing / .expired`, driven by
call outcomes (Portal has nothing to watch passively). `provider.refreshSession()` forces a
re-mint + rebuild, `provider.updateSessionToken(_:)` installs a host-minted token (a token that
cannot be installed throws `.invalidConfig` and leaves the current client untouched), and
`provider.close()` silences a provider you are discarding.

Reference: the example app's `RainSDKService.swift`, `WalletSessionStatus.swift` and `HomeView`'s
session card.
