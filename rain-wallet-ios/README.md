# RainWallet

The Rain-branded wallet provider for the modular Rain iOS SDK.

The wallet backend identity is embedded in the SDK. The SDK owns the whole wallet lifecycle:
authentication (one-time codes over email or SMS, and passkeys), wallet provisioning (EVM +
Solana on first login), session management, and the full `RainClient` surface. Linking
`rain-wallet-ios` is all an app needs: `RainCore` comes transitively (and is re-exported, so
`import RainWallet` surfaces the full SDK).

Code login runs against Rain's API and needs one thing from you: a **wallet auth token**, which
**your backend** mints with your Rain Api-Key (`POST /v1/issuing/embedded-wallets/auth-tokens`,
body `{ "contact": { "type": "email" | "phone", "value": "…" } }`) and hands to the app. The
token lives ten minutes, is bound to that one contact, and is consumed by login — so the SDK
asks for a fresh one at the start of every code flow through `authTokenProvider`. Never put the
Api-Key in the app.

```swift
import RainWallet   // re-exports RainCore

let provider = RainProvider(RainWalletConfig(
    environment: .sandbox,                                 // .production is the default
    authTokenProvider: { contact in                        // called per code flow
        try await myBackend.walletAuthToken(for: contact)  // your backend → Rain /auth-tokens
    }
))

// Reuse a restored session, or run the login-code flow (email or SMS):
await provider.awaitSessionRestore()
if !provider.hasActiveSession() {
    try await provider.sendLoginCode(to: .email("user@example.com"))  // or .phone("+1555...")
    try await provider.confirmLoginCode(code) // signup-or-login + EVM/Solana wallet provisioning
    // ...or passkeys: loginWithPasskey(anchor:) / signUpWithPasskey(anchor:)
}

let rain = try RainSdk.builder()
    .rpcEndpoints([43114: "https://…"])
    .register(provider)
    .build()
let client = try await rain.provider(.rain)
```

`authState` / `currentAuthState()` report `.loading` / `.authenticated` / `.unauthenticated` over
time and right now; `sessionState` / `currentSessionState()` do the same for the session
(`RainWalletSessionState`, `.active(expiresAtEpochSeconds:)` while live). `refreshSession()`
forces a refresh, `logout()` clears the stored session, and `close()` makes the provider inert
when you discard it — the session watcher stops and every auth/export call throws
`invalidConfig` afterwards.
Configure expiry/refresh/retry behavior via `RainWalletConfig.sessionPolicy`
(`RainWalletSessionPolicy`) and react to unrecoverable expiry via `onSessionExpired`.

## Passkeys and login contacts

`signUpWithPasskey(anchor:)` creates a NEW account (fresh wallet — returning users must use
`loginWithPasskey(anchor:)` or a login code, or they end up with a second, empty account). It
needs a contact-less wallet auth token, so your `authTokenProvider` is called with `nil`; expect
two biometric prompts — one to register the passkey, one to sign in with it;
`addPasskey(anchor:)` registers a passkey on the current account so the next login can skip the
code. Passkeys use YOUR domain: set `RainWalletConfig(passkeyDomain:)` to a web domain you
control, serve `/.well-known/apple-app-site-association` on it listing your app under
`webcredentials`, and add the `webcredentials:<domain>` Associated Domains entitlement. Without
a configured domain the passkey methods throw `invalidConfig`. The domain is permanent — your
users' passkeys are bound to it — and passkeys from one domain don't work in apps on another.
A passkey-created account can attach a verified email or phone with
`sendContactVerificationCode(to:)` + `confirmContactVerification(_:)`, after which that contact
is a login method too. SMS login requires SMS auth enabled on the wallet backend. Accounts are
never merged: attaching a contact adds a login method to THIS account; it never moves wallets.

## Key export

The account has ONE wallet seed covering both chain families, so a single recovery phrase
restores everything. With an active session:

```swift
let phrase = try await provider.exportRecoveryPhrase()          // 12 words (BIP-39)
let ethKey = try await provider.exportPrivateKey(.ethereum)     // 0x-prefixed 32-byte hex
let solKey = try await provider.exportPrivateKey(.solana)       // Base58, importable by Solana wallets
```

Decryption happens on-device and the SDK never logs or persists the values. Everything after the
return is the app's responsibility: gate the call (e.g. behind biometrics), display the secret
without screenshots/screen recording where possible, and keep it off the pasteboard. The Android
SDK returns the same formats.

Notes:

- Without an `authTokenProvider`, `sendLoginCode` and `sendContactVerificationCode` throw
  `invalidConfig`; passkey login still works, so `RainProvider()` is valid for passkey-only apps.
- Wallets are per partner: the same email in two partner apps is two wallets.
- Logging in on a second device does not log the first one out.
- Errors: a wrong code is `invalidLoginCode` (RAIN_203, retype); a rejected or expired token is
  renewed from your provider once, then `unauthorized` (RAIN_202); a tenant that cannot use
  embedded wallets is `unauthorized` too; rate limits and backend outages are `providerError`.
- The wallet-backend configuration is one-shot per app launch.
- The Rain wallet provider cannot be registered alongside the Turnkey provider in one app
  (`RainSdk.build()` rejects the combination); they share one process-wide wallet backend.
- Multi-chain: the same provider serves EVM chains and Solana clusters
  (`RainChain.solanaMainnet` / `.solanaDevnet` / `.solanaTestnet`). Advertised capabilities:
  `.export`, `.multiChain`, plus `.gasSponsorship` when `sponsorGas` is on.
