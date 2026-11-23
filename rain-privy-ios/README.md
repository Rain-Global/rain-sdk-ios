# RainPrivy

The [Privy](https://www.privy.io) embedded-key adapter for the modular Rain iOS SDK.

Depends on `RainCore` + the Privy iOS SDK (`Privy`, binary xcframework). Linking `RainPrivy` is all
a Privy-only app needs: `RainCore` comes transitively, and Portal's / Turnkey's vendor SDKs never
enter the dependency graph.

Privy authentication and embedded-wallet provisioning happen outside Rain: initialize the `Privy`
singleton at app start, log the user in, ensure an embedded Ethereum wallet exists
(`user.createEthereumWallet()`), then hand the singleton to Rain.

```swift
import RainPrivy   // re-exports RainCore

// Host app: authenticate with the Privy iOS SDK and ensure an embedded Ethereum wallet exists.

let rain = try RainSdk.builder()
    .rpcEndpoints([43114: "https://avalanche-c-chain-rpc.publicnode.com"])
    .register(PrivyProvider(PrivyConfig(privy: privy)))
    .build()

let client = try await rain.provider(.privy)
```

This module owns everything Privy-specific: the `PrivyProvider` descriptor, the
`PrivyWalletProvider` (mapping Privy onto `WalletProvider`), the Privy RPC client used for
balance / fee reads against Rain's configured endpoints, and Privy error mapping (registered with
`RainCore` at runtime so core stays Privy-free).

Custody (signing, broadcasting) routes through Privy's EIP-1193 embedded wallet; transaction
history comes from Privy's indexer on the chains it supports (unsupported chains return an empty
list). Resolving `rain.provider(.privy)` probes for an embedded Ethereum wallet and throws
`RainError.walletUnavailable` if none is available.

Advertised capabilities: `.export`, `.recovery`, `.multiChain`.

## Session expiry and retry

Privy's session model differs from Turnkey's: the Privy SDK refreshes its own session
internally before every wallet and indexer call, and exposes no JWT expiry. Rain therefore does
not schedule refreshes for Privy — hardening is auth-state guarding, a re-auth hook, and
transient-failure backoff, controlled by `PrivySessionPolicy`:

```swift
PrivyProvider(
  PrivyConfig(
    privy: privy,
    sessionPolicy: PrivySessionPolicy(
      maxTransientRetries: 2,   // backoff retries for network failures on reads
      initialRetryDelay: 0.5,
      maxRetryDelay: 4
    ),
    onSessionExpired: {
      // Re-auth hook: the session died (Privy's own internal refresh already failed).
      // Fired once per session death. Route the user back to login.
    }
  )
)
```

What every wallet call now does:

1. **Auth-state check** — Privy's auth state is consulted before the request: an
   unauthenticated state throws `RainError.tokenExpired` without a round-trip, and a call
   racing Privy's async credential restore waits out `.loading` (bounded at ~10s) instead of
   misreporting expiry.
2. **Terminal auth failures** — an auth failure that reaches Rain means Privy already tried
   its own internal refresh, so it surfaces immediately as `RainError.tokenExpired` (never
   retried) and fires the hook. Privy's `sessionExpired` error code now maps to
   `.tokenExpired` too.
3. **Transient backoff** — idempotent reads (address resolution, history) retry network
   failures with exponential backoff. Sends and signing are never retried.
4. **Re-auth hook + cache eviction** — when an active session dies, `onSessionExpired` fires
   once (even with no Rain call in flight, via a passive watcher over Privy's auth-state
   stream) and the adapter's cached accounts are evicted, so a later login as a different user
   can never sign with the previous user's wallets.

Observable state: `provider.sessionState` (`AnyPublisher<PrivySessionState, Never>`) and
`provider.currentSessionState()` report `.loading / .active / .unverified / .unauthenticated`.
`.unverified` is Privy-specific (a session restored offline that Privy could not verify yet);
there is no `.expired` state because Privy exposes no expiry timestamp. `provider.refreshSession()`
is a manual health check that throws `.tokenExpired` on failure.

Resolving the provider always starts the passive watcher (it also drives cache eviction). A
host that rebuilds the SDK per login should call `provider.close()` on the provider it is
discarding so a stale watcher cannot fire.

Reference: the example app's `RainSDKService.swift`, `WalletSessionStatus.swift` and `HomeView`'s
session card.
