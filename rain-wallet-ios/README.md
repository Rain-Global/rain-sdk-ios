# RainWallet

The Rain-branded wallet provider for the modular Rain iOS SDK.

The wallet backend identity is embedded in the SDK, one per environment: `.sandbox`
(`api-dev.rain.xyz`) and `.production` (`api.rain.xyz`) each fix both the Rain API host and the
wallet organization, so accounts never cross between them. The SDK owns the whole wallet lifecycle:
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
    switch try await provider.confirmLoginCode(code) { // signup-or-login + EVM/Solana wallet provisioning
    case .signedIn:
        break
    case .secondCodeRequired(let contact):           // this account is protected with two codes
        try await provider.sendSecondLoginCode()     // Rain sends it to contact.masked
        try await provider.confirmSecondLoginCode(secondCode)
    }
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
forces a refresh (`tokenExpired` only when the backend refuses it; offline is `networkError` with
the session kept), `logout()` clears the stored session, and `close()` makes the provider inert
when you discard it — the session watcher stops and every auth/export call throws
`invalidConfig` afterwards.
Configure expiry/refresh/retry behavior via `RainWalletConfig.sessionPolicy`
(`RainWalletSessionPolicy`) and react to unrecoverable expiry via `onSessionExpired`.

## Two-code login

When the tenant setting is on and the account has both an email and a phone, Rain requires a
code from each. `confirmLoginCode` then returns `.secondCodeRequired(contact)` instead of
`.signedIn`, with the first code spent and nothing logged in: `contact.kind` and `contact.masked`
(`j•••@example.com`, `+•••• 4567`, as Rain sent it) say where the second code will go. Call
`sendSecondLoginCode()` to have Rain send it (call again to resend; five per attempt), then
`confirmSecondLoginCode(code)`. The whole attempt rides on the first code's wallet auth token, so
`authTokenProvider` is not called again, and it lives as long as that token (ten minutes). A
wrong second code (`invalidLoginCode`) keeps the attempt; every other failure of the confirm,
a transport failure included, ends it, and `sendLoginCode` starts over (a failed send keeps it). A new `sendLoginCode`, `logout()`, `close()` or
a passkey sign-in/sign-up abandons an attempt between its codes and deletes its device key. Don't ignore `confirmLoginCode`'s result:
a `switch` over `RainWalletLoginOutcome` is exhaustive.

## Passkeys and login contacts

`signUpWithPasskey(anchor:)` creates a NEW account (fresh wallet — returning users must use
`loginWithPasskey(anchor:)` or a login code, or they end up with a second, empty account), and
throws `invalidConfig` while any session is live, so a double tap can't mint one either. It
needs a contact-less wallet auth token, so your `authTokenProvider` is called with `nil`. One
biometric prompt registers the passkey; the session is then opened with a short-lived key the
backend attaches to the new account. A second prompt appears only when that key cannot open the
session — the backend recovered an earlier interrupted attempt, the key expired, or the request
failed — and it is addressed to the account the backend returned, so it opens no other. If the signup's outcome is unknown (a timeout, a
backend error), the SDK keeps the registered passkey and the next `signUpWithPasskey` call
resends it without a new prompt — never register a second one yourself. A `providerError` whose message says the signup is still in progress means the
backend is finishing the earlier attempt: ask the user to try again in a couple of minutes;
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
If the contact is already the login for another wallet in your app, or its account is protected
with two codes, the attach is refused with `unauthorized` (RAIN_202) once the code is confirmed
— tell the user to sign in with that contact instead. Re-attaching a contact the account already has is fine, unless the account is protected with two codes: then it is refused the same way.

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
- The wallet-backend configuration is one-shot per app launch: a second provider with a different
  environment in the same launch throws `invalidConfig` from every auth call.
- The Rain wallet provider cannot be registered alongside the Turnkey provider in one app
  (`RainSdk.build()` rejects the combination); they share one process-wide wallet backend.
- Multi-chain: the same provider serves EVM chains and Solana clusters
  (`RainChain.solanaMainnet` / `.solanaDevnet` / `.solanaTestnet`). Advertised capabilities:
  `.export`, `.multiChain`, plus `.gasSponsorship` when `sponsorGas` is on.
