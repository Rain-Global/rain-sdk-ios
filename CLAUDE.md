# Claude Code Instructions

## Git
- Never commit or push changes unless explicitly asked.
- Commit messages: single line only, no body. No conventional-commit prefixes (no `feat:`/`fix(scope):`). Always start with a capital letter.
- PR descriptions: human voice — first person, plain sentences, brief; cover the substance without exhaustive bullet inventories or marketing polish. Follow `.github/pull_request_template.md`. Concise: Why/What/Solution a short paragraph each, readable in two minutes; one fact per sentence; no vendor-source trivia, no history of how we got there, no restating what the diff shows. Test plan names what is covered, not every test.

## Code comments
- Only where the code cannot say it: a vendor or protocol fact, a non-obvious consequence, a
  fixture's meaning, a deliberate divergence from the obvious choice. Never what the next line
  does, never why the design is good, never history. Public API docstrings state the contract
  and what a host must know, not the implementation. In tests, put the reasoning in the
  `#expect` message, not a comment above it. Review the diff's comments before every PR and cut.

## Build & test
- Test command: `xcodebuild -scheme RainSDK-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test` (always use the iPhone 18 Pro simulator).

## Architecture (post Turnkey extraction, 2026-09-03)

Modular, ports & adapters. One SPM package (internal name `RainSDK`), one product per provider;
clients link only the providers they use. Every adapter `@_exported import`s RainCore, so one
import per provider suffices. The 1.x `RainSDK` umbrella module has been REMOVED.

- `RainCore` (`rain-core-ios`) — vendor-free hexagon: `WalletProvider` port, `ProviderDescriptor`
  descriptors, `Capability` model, `RainSdk` builder/registry (caches in-flight resolution Tasks),
  `RainClient` (impl `RainSdkManager`), transaction building, EIP-712, EVM chain reader
  (JSON-RPC + Multicall3), Solana stack (sentinel ids 900/901/902), token store, Auth Pull
  (ERC-20 allowance surface), error model. NO Rain issuing API client (REMOVED 2026-09-18, PR F):
  fetching the collateral contract + admin withdrawal signature is the HOST's job (server-side,
  Api-Key off-device); the SDK only takes the results as `RainWithdrawAddresses` /
  `RainAdminSignature`. Token enrichment STAYS in the SDK as a public, wallet-agnostic
  `RainSdk.tokenMetadata(chainId:address:) -> TokenInfo?` (strict: nil when decimals unresolved,
  never the 18 default; Solana registry-only) over `TokenMetadataStore.resolvedTokenInfo`. The
  demo ships its own reference `RainApiClient`
  (`Example/.../Core/Services/RainApiClient.swift`). `RainApiEnvironment` is gone from the SDK;
  Auth Pull validation keys off `RainAuthPullConfig.kind` alone (`.custom` may use either
  environment's chains). Error codes COMPACTED (no external users yet; Android to follow):
  `chainNotSupported` moved RAIN_105 → RAIN_104; `apiError` (RAIN_302, nothing threw it once the
  Rain API client left — the adapters' `.apiError` matches are Turnkey's own type) dropped and
  `transactionPending` moved RAIN_303 → RAIN_302; RAIN_304 dropped. 303/304 are never reused: a
  new 3xx starts at 305 — `transactionOutcomeUnknown` = RAIN_305 (added 2026-10-14, same as
  Android), a new 1xx at 106. No wallet vendor SDKs. EVM ABI encoding + collateral contract reads go through
  Boilertalk Web3.swift ONLY — web3swift was REMOVED 2026-09-15 (abandoned upstream since 2025;
  its URLSession overload trick stopped compiling on new Xcode). Contract call outputs from
  Boilertalk decode under the ABI output NAME as key ("" for unnamed outputs, not "0").
  BigInt is PINNED `exact: "5.3.0"` and declared directly on every module (beta.1 A1 finding,
  2026-09-29): tkhq/swift-sdk 4.0.0 → anquii/Base58 1.0.0 hard-pins `.exact("5.3.0")`, so
  fresh consumers can only ever resolve 5.3.0, which predates `Sendable` on `BigUInt` (5.4.0) —
  the repo's stale 5.4.1 pin in Package.resolved was masking it (SwiftPM honours committed pins
  without rechecking transitive exacts; CI clones the pin). RainCore carries
  `extension BigUInt: @retroactive @unchecked Sendable {}` (`Utils/Extensions/BigInt+Sendable.swift`);
  the exact pin is what keeps it from becoming a redundant-conformance error. Lift pin + delete
  shim TOGETHER once Turnkey's graph allows a newer BigInt. Test A1 (fresh host package at the
  tag, `exact:`) is the regression check — never trust the in-repo build for this.
- `RainTurnkey` (`rain-turnkey-ios`) — Turnkey adapter, BYO + managed modes (multi-chain
  EVM+Solana; `.export`, `.multiChain` — NOT `.biometricGate`: the vendor's enclave key has a
  `.none` auth policy, nothing gates signing). `RainPortal` (`rain-portal-ios`) — Portal MPC,
  EVM-only. `RainPrivy` (`rain-privy-ios`) — Privy embedded wallet (EIP-1193 custody, reads via
  Rain RPC). `RainWallet` (`rain-wallet-ios`) — Rain-branded provider: a wallet-neutral renaming
  layer over managed RainTurnkey (descriptor struct `RainProvider`, id `.rain`, embedded backend
  identity — `RainWalletConfig` carries behavior only, `RainProvider()` is zero-config); `@_spi(RainWallet) internal import RainTurnkey`
  so no vendor type can leak into its public surface (compiler-enforced), @_exported RainCore
  only; mutually
  exclusive with `.turnkey` (guard in `RainSdk.build()`). Test seams for managed providers:
  `TurnkeyManagedConfigurator.configureImpl` + `.sharedContext` (the vendor singleton traps
  unconfigured in test hosts).
- Adapters follow one shape: descriptor + config, wallet adapter over the vendor SDK, session
  coordinator/policy (`onSessionExpired`), error mapping registered via
  `RainError.registerErrorMapper` from the provider's init. Portal/Privy: auth happens OUTSIDE
  Rain (host hands in an authenticated vendor object). Turnkey has two modes: BYO (same), and
  MANAGED — `TurnkeyConfig(organizationId:authBackend:)` (NO auth-proxy id since PR H4: the
  vendor's `client` is nil until a session exists, which every SDK call already guards for;
  passkey login builds its own client), SDK configures the TurnkeyContext singleton (one-shot per
  process, TurnkeyManagedConfigurator keyed on org id + rpId + rain-api base URL) and TurnkeyProvider exposes auth
  (sendLoginCode/confirmLoginCode/passkeys/logout/authState) over rain-api + EVM/Solana wallet
  provisioning on login.
- SPI convention: adapter modules reach core internals via `@_spi(RainAdapter) import RainCore`
  (`ChainReader`/`MinedReceipt`, `ProviderContext.evmChainReader`, `RainSolanaSupport` seams,
  `SolanaRpcClient`, `SolanaTransferComposer`, `JsonRpcClient`, `SolanaTransactionDecoder`,
  `SolanaConverter`, `TokenMetadataStore.init`, `String.strippingHexPrefix`, `Base58`,
  `RainChain.solanaNativeCurrency`). Not API for host apps. Note: public types don't get Sendable
  inference — declare it when widening. Tests touching SPI symbols need
  `@_spi(RainAdapter) @testable import RainCore`.
- Test targets can `@testable import` any package target but not other test targets — each
  adapter's test target duplicates the helpers it needs (TestFixtures, MockChainReader,
  MockURLProtocol, etc.).

## Naming (renamed 2026-09-04, PR A of the RainWallet work)

The `RainWallet*` namespace belongs exclusively to the upcoming Rain-branded module. Renames:
port `RainWalletProvider` -> `WalletProvider`; descriptor protocol
`RainProvider` -> `ProviderDescriptor` (NO typealias — the name is reserved for the new module's
descriptor struct). No typealiases at all: both renames are clean breaks in the v5 release.

## Planned next

Phase 2 (replanned 2026-09-07) — auth moves INSIDE the SDK for Turnkey and RainWallet:

- PR B1 (DONE 2026-09-07; reworked 2026-09-09), RainTurnkey managed auth — SPI-only: `TurnkeyConfig`
  gains a managed init (`organizationId` + `authProxyConfigId`; the proxy id REMOVED in H4) alongside the existing BYO
  authenticated-context init (kept, non-breaking). Managed mode: the SDK calls
  `TurnkeyContext.configure` itself (singleton, process-guarded) and `TurnkeyProvider` exposes
  auth — email OTP only: `sendLoginCode(email:)` / `confirmLoginCode(_:)` (ORIGINALLY vendor
  initOtp → verifyOtp + completeOtp via the Auth Proxy, under a per-attempt session key,
  login-or-signup; SUPERSEDED by rain-api in PR H2 — same per-attempt-key dance, different
  backend; wrong code = `invalidLoginCode` RAIN_203, never a logout), `logout()`, `authState`
  publisher mapped to a Rain-owned enum.
  Provisioning: ONE wallet with both the Ethereum and Solana accounts (single seed; atomic at
  signup via `createSubOrgParams.customWallet`, backfilled onto the existing seed via
  `create_wallet_accounts` otherwise) — a cross-platform contract with Android. Auth calls in
  BYO mode throw invalidConfig. DECISION 2026-09-09: the managed surface (managed init, auth
  extension, `TurnkeyAuthState`) is `@_spi(RainWallet)` — publicly Turnkey is BYO-only like
  Portal/Privy; managed auth ships to hosts exclusively through RainWallet, whose module uses
  `@_spi(RainWallet) internal import RainTurnkey`. Demo Turnkey tab stays full BYO
  (TurnkeyAuthSample drives the vendor SDK); managed email-OTP is demoed on the Rain Wallet tab.
- PR B2 (DONE 2026-09-07; ids embedded 2026-09-11), `rain-wallet-ios` / `RainWallet`: renaming
  layer over managed RainTurnkey. DECISION 2026-09-11 (reverses the earlier host-supplied
  design): Rain's org id is EMBEDDED in the module, PER ENVIRONMENT since WALL-150
  (2026-10-24): `RainWalletEnvironment.organizationId` — sandbox = `63495e45-…`, production =
  `306c2e82-5ae2-4be6-8b41-1ab0cc6b0ab5` (separate Turnkey parent orgs, so the configurator's
  org-id key already separates environments; `RainWalletBackend` DELETED, `.authConfigId` went
  earlier with the Auth Proxy in H4). Public identifiers, not secrets; abuse bounded by rate
  limits. The pending passkey signup store is keyed per org
  (`UserDefaultsPendingPasskeySignupStore(organizationId:)`, no default on the controller init). `RainWalletConfig(walletAddress:sessionPolicy:onSessionExpired:)`
  carries behavior only, and `RainProvider()` is zero-config (defaulted init). Descriptor struct
  `RainProvider`, id `ProviderId.rain`, neutral session surface (`RainWalletSessionState`,
  publisher, refreshSession). RainWallet @_exported imports RainCore only — NEVER RainTurnkey
  (no Turnkey symbol on a bare `import RainWallet`). Mutual exclusion guard in `RainSdk.build()`
  (.rain + .turnkey cannot both register — one TurnkeyContext per process). Demo app has a
  RainWallet provider option (email-only entry — no id fields; email OTP via the RainWallet
  methods, then the standard wallet screens), linking rain-wallet-ios.
- PR C (DONE 2026-09-11, merged as #36), key export — RainWallet-only, same SPI shape as
  managed auth.
  Public surface: `RainProvider.exportRecoveryPhrase()` (12-word BIP-39 phrase of the account's
  single seed) and `exportPrivateKey(_: RainWalletKeyAccount)` (`.ethereum` = 0x-prefixed 32-byte
  hex; `.solana` = plain Base58 of priv‖pub, no checksum — NOT the vendor's Base58Check, which
  Phantom rejects; built via CryptoKit ed25519 pubkey derivation + core's SPI Base58) — formats
  are a cross-platform contract with Android.
  Machinery: `TurnkeyContextProtocol.exportWalletMnemonic(walletId:)` (vendor `exportWallet`) and
  `exportAccountPrivateKey(address:encoding:)` (composed: generateP256KeyPair →
  client.exportWalletAccount → TurnkeyCrypto.decryptExportBundle, all on-device; no high-level
  per-account export at swift-sdk 4.0.0). Provider surface `exportMnemonic()` /
  `exportPrivateKey(family:)` is `@_spi(RainWallet)`; BYO mode throws invalidConfig. Legacy
  accounts (pre one-seed) can hold several wallets/seeds: the mnemonic export anchors on the
  wallet carrying the Ethereum account so phrase and exported ETH key always agree. The SDK
  never logs/persists exported values; gating (biometrics) and safe display are the host's job.
  RainTurnkey now also depends on the TurnkeyCrypto product. Demo: "Export keys" card on the
  Rain Wallet tab (tap-to-reveal, `.privacySensitive()`, value never logged; Copy uses a
  local-only pasteboard entry that self-expires after 60 s).
- PR D (DONE 2026-09-18, merged as #38), passkeys + SMS OTP for
  RainWallet — same SPI shape as managed auth. Public surface: `RainWalletContact`
  (.email/.phone) with `sendLoginCode(to:)` REPLACING `sendLoginCode(email:)` (clean break,
  v5 stance; confirmLoginCode unchanged — SMS reuses the whole OTP pipeline, vendor `.sms`);
  `signUpWithPasskey(anchor:)` / `loginWithPasskey(anchor:)` / `addPasskey(anchor:)` (add =
  raw client.createAuthenticators + TurnkeyPasskeys createPasskey ceremony on the live session,
  composed like export); contact-attach for passkey accounts:
  `sendContactVerificationCode(to:)` + `confirmContactVerification(_:)` (vendor verifyOtp →
  verificationToken → updateUserEmail/updateUserPhoneNumber so the contact lands VERIFIED and
  becomes a login method). Vendor facts (verified at 4.0.0): passkey flows accept a `sessionKey`
  param but IGNORE it — sessions always store under "com.turnkey.sdk.session" and storeSession
  throws keyAlreadyExists on an occupied key, so the controller needs a passkey session dance
  (pre-purge the default key only when it is NOT the live selection; explicit select after;
  purge the superseded per-attempt key; and REFUSE login/signup up front over a LIVE passkey
  session — the vendor stores the session LAST, so letting the ceremony run would mint an
  orphan passkey + for signup an orphan account before failing on the occupied key; an EXPIRED
  session under the selected default key is purged instead, waiting out the vendor's async
  state flip, and the ceremony proceeds); passkey signup merges our one-seed `customWallet`
  into CreateSubOrgParams (atomic provisioning holds); signup's stampLogin passes
  invalidateExisting: true but LOGIN's does not (single-active-session gap — flag upstream +
  Android). DECISION 2026-09-15 (reverses 2026-09-14's shared-Rain-domain plan): the passkey
  relying-party domain is PARTNER-SUPPLIED — `RainWalletConfig(passkeyDomain:)`, nil = passkeys
  off (invalidConfig). Each partner hosts their own AASA/assetlinks files and entitlement; Rain
  runs no shared passkey domain, and passkeys are per-partner (not portable across partner apps;
  the same account can hold passkeys from several domains). rpId still joins the one-shot vendor
  configure and is one-shot per launch. SMS is Turnkey-Enterprise
  (FEATURE_NAME_SMS_AUTH on Rain's org; since PR H2 the code is sent by rain-api from the
  PARENT org — sandbox +1 999-999-9999 / 000000 needs alphanumeric=false, otpLength=6 on
  rain-api's init, guide open question #5b). Accounts NEVER merge
  (sub-org = account boundary): docs steer returning users to login/add-passkey, not signup;
  OPEN QUESTION to test + confirm with Turnkey: attaching a contact already owned by another
  sub-org (rejected, or ambiguous for contact-based login lookup?). Demo: email/phone toggle on
  the code flow + three passkey buttons (sign in / create / add). Everything here is a
  cross-platform contract with Android.
  Contact normalization (`TurnkeyLoginContact.normalized()`, one funnel for login AND contact
  attach): emails trimmed + LOWERCASED (beta finding 2026-10-05 — Turnkey compares contacts
  byte-for-byte, so `Volo@` and `volo@` minted two accounts/wallets), phones to E.164. The
  normalized string IS the account identity: Android must lowercase identically — flag for
  parity. Any pre-fix account created with a mixed-case email is now unreachable by that
  email (beta only, no external users).
- PR H1 (DONE 2026-10-20, #45: `RainApiAuthClient`) + PR H2 (IN PROGRESS 2026-10-21, branch
  volo/feature/rain-api-code-login) — managed auth moves OFF Turnkey's Auth Proxy onto rain-api
  (`/v1/issuing/embedded-wallets`), RainWallet only, HARD CUTOVER (decision 2026-10-20: no
  proxy path kept; beta Auth-Proxy accounts become unreachable — rain-api never recorded their
  sub-orgs). H2 SHAPE: `TurnkeyContextProtocol` lost `sendOtp`/`completeOtp`/`verifyOtpToken`
  and gained the device-crypto seams (`createOtpKeyPair`, `encryptOtpCode`,
  `clientSignatureForLogin/ForSignup`, `signClientMessage`, `storeTurnkeySession`) so the
  crypto stays mockable; `TurnkeyManagedAuthController` takes `api: RainApiAuthClientProtocol`
  + `tokenProvider`, keeps its per-attempt-key/select/purge dance, and flows: mint token →
  /otp/init → (confirm) fresh key → encrypt → /otp/verify (400 invalid code keeps the attempt,
  any other failure ends it) → forLogin+sign → /login; `.noWallet` → forSignup+sign (contact
  only) → /signup → /login again with subOrganizationId, same token + verification token.
  `.tokenRejected` mid-flow → ONE renewal from the host (`withTokenRetry`). Contact attach =
  token for the NEW contact → init/verify → vendor `updateUserEmail/Phone` with rain-api's
  verification token. OWNERSHIP CHECK (2026-10-26, branch
  volo/feature/refuse-contact-attach-to-other-wallet): `/otp/verify` also returns
  `walletSubOrganizationId: String?` — the wallet this tenant has SAVED for the token's contact
  (looked up only after the code verified, so the caller already proved they own the contact);
  `confirmContactVerification` throws `unauthorized` RAIN_202 and drops the challenge when it
  is set and ≠ `session.organizationId` (the id, not a Bool, so re-attaching one's own contact
  still works). Without it the attach went through, rain-api then found TWO wallets for the
  contact and every code login 500'd (`findSavedSubOrg`), and the vendor update REPLACES the
  account's existing email, so both wallets could lose code login. The pre-rain-api SDK asked
  the Auth Proxy; Android's cutover (#77) dropped the check — flag for parity (same field).
  Login (`confirmLoginCode`) ignores the field. `TurnkeyConfig` managed init requires `authBackend:
  TurnkeyManagedAuthBackend(baseURL:tokenProvider:)` (SPI). `invalidateExisting` is GONE: a
  second device no longer logs the first out (test plan B7 now expects success — backend ask).
  PR H3 (DONE 2026-10-22, #47): passkey SIGNUP
  = `mintToken(for: nil)` (contact-less, BEFORE Face ID so a host without a backend fails
  first) → `context.registerPasskey(anchor:rpId:)` (the platform ceremony alone, returns
  module-owned `PasskeyRegistration` = challenge + v1Attestation fields, transports as raw
  values) → `/signup/passkey` (409 → invalidConfig steering to loginWithPasskey; other
  refusals mapped) → session. ONE-PROMPT SESSION (PR H5, 2026-10-26, branch
  volo/feature/passkey-signup-session-key; replaces the SECOND biometric prompt H3 shipped with):
  the device makes an in-memory P256 pair per attempt (`context.makeTemporaryApiKey()`
  = vendor `TurnkeyCrypto.generateP256KeyPair`, compressed pubkey hex; NEVER persisted — review
  H5: the vendor's own signup keeps it a local, and a resend makes a fresh one;
  `registration.apiAttestation(loginKey:)` joins them at call time), sends `publicKey`
  top-level on `/signup/passkey`, rain-api attaches it to the new root user as a 60 s API key
  (`SESSION_KEY_SECONDS`, `embeddedWalletSignupController.ts`), and
  `context.loginWithTemporaryKey(organizationId:key:sessionKey:)` does what the vendor's
  proxy-era signup did (verified in source, TurnkeyContext+Passkey.swift):
  `TurnkeyClient(apiPrivateKey:apiPublicKey:organizationId:)` (baseUrl default = the context's
  host) → `createKeyPair()` for the session key → `stampLogin(expirationSeconds: "900",
  invalidateExisting: false)` → `storeSession(jwt:sessionKey:)` under a per-attempt key like
  the code flow (`activateStoredSession` is now shared by both). The key only exists on the
  account the signup created → the session can only be for that account (the second passkey
  prompt listed every look-alike `passkey-<ts>` for the domain and could sign into an OLD
  account while the SDK reported success). FALLBACK: a failed key login (anything but
  cancellation) stores nothing, so the controller runs the old `loginWithTurnkeyPasskey` path
  (second prompt) SCOPED to the signup's sub-org (`loginWithTurnkeyPasskey(anchor:organizationId:)`
  → vendor `loginWithPasskey(anchor:organizationId:)`, which stamps `stamp_login` on that org, so
  a look-alike passkey from another account FAILS instead of signing in — review H5, Android
  passes it too; normal `loginWithPasskey` passes nil = parent org) — the only expected cause is rain-api ADOPTING an unsaved account this tenant
  created earlier (no key attached; the response is identical `{subOrganizationId}`, so the
  device cannot tell — backend ask: a `sessionKeyAttached: false` flag) or the 60 s passing. A
  resend answered 409 "already has a wallet" returns no sub-org id → passkey login. A resend
  whose first try DID land is answered by the adopt path (no key) → passkey login too, so
  reusing the key across a resend would buy nothing. `signUpWithPasskey` is REFUSED over ANY
  live session (`hasActiveSession()` → invalidConfig, review H5: the attempt-key store slipped
  past `refuseIfLivePasskeySession`, which only sees the vendor's default key, so a double tap
  after a key-path signup minted an empty second account; Android refuses the same way;
  `refuseIfLivePasskeySession` stays for its expired-default-key purge). Android: same change
  once its passkey signup is on rain-api.
  `signUpWithTurnkeyPasskey` (vendor proxy signup + customWallet) is GONE;
  `addPasskeyAuthenticator` unchanged. UNKNOWN-OUTCOME RULE (review #47): rain-api keeps
  creating the account past our timeout and only RECORDS a lost account when the SAME credential
  is resent to /signup/passkey — a dropped registration would mean a second passkey + second
  account while the first passkey still signs into an account Rain cannot see (webhooks dropped,
  absent from dashboards). So the registration is saved to `PendingPasskeySignupStore`
  (UserDefaults, public attestation material) BEFORE the call; transport/5xx/429/cancellation
  keep it, and the next `signUpWithPasskey` RESENDS it (no ceremony, fresh token). Resend
  endings: 409 "wallet" → account exists → login; 409 "progress" → 120 s backend lock →
  `providerError(TurnkeyPasskeySignupInProgress)`, keep; definitive refusals clear. Token
  rejected at /signup/passkey → ONE renewal (same rule as codes). Failure residue: a refused
  signup leaves a keychain passkey no account knows; a failed post-signup login leaves an
  account the passkey can `loginWithPasskey` into.
  PR H4 (DONE 2026-10-23, branch volo/refactor/drop-auth-proxy-config): `authProxyConfigId`
  REMOVED everywhere managed — `RainWalletBackend.authConfigId`, the `Mode.managed` field, the
  managed init, `TurnkeyManagedConfigurator.configure(organizationId:rpId:authBaseURL:)`
  (configureImpl is `(String, String?)`, the vendor config gets `authProxyConfigId: nil`; the
  one-shot guard is keyed on org id + rpId + rain-api base URL — review: two environments in one
  launch would share the vendor's single session store; same key as Android). VENDOR FACT (verified
  2026-10-23): `TurnkeyContext.client` is nil without the proxy id UNTIL a session exists
  (+Session.swift sets it); passkey login builds its own passkey-stamped client and `stampLogin`s
  directly. The demo's BYO Turnkey tab still uses the proxy — the HOST's choice, untouched. Demo: `RainApiClient.mintWalletAuthToken` (Api-Key on device = DEMO ONLY, loud
  comment) feeds `prepareRainWallet`'s provider. Host surface: `RainWalletConfig`
  gains `environment: .sandbox(api-dev.rain.xyz) / .production(api.rain.xyz)` (`.custom` REMOVED
  in WALL-150 — each environment fixes host AND org, parity with Android + web)
  (DEFAULT .production) and `authTokenProvider: (RainWalletContact?) async throws -> String`
  (nil → code flows throw invalidConfig, passkey login works) — the PARTNER BACKEND
  mints the wallet auth token (`wat_…`, 10-min TTL, bound to one contact, contact-less only for
  passkey signup, consumed by /login and /signup/passkey but NOT /signup) with its Api-Key via
  `POST /auth-tokens`; the device never sends a contact. Device endpoints (Bearer wat_): /otp/init,
  /otp/verify, /signup (idempotent, returns subOrganizationId, no session), /login (404 = no
  wallet → signup then login again on the SAME token + verification token; 900 s session; EVM
  address LOWERCASED), /signup/passkey. Rate limit 30/5 min per IP; only DEV has Turnkey
  configured (elsewhere 503). After login everything is device→Turnkey as today.
  VENDOR FACTS (swift-sdk 4.0.0, verified in source 2026-10-20) — all PUBLIC: the device does
  what the proxy flow did: `TurnkeyContext.createKeyPair()` (keychain, returns hex pubkey);
  `TurnkeyCrypto.encryptOtpCodeToBundle(otpCode:otpEncryptionTargetBundle:publicKey:)`; Turnkey
  embeds that pubkey in the verification token, and `ClientSignature.forLogin(verificationToken:)`
  / `forSignup(verificationToken:email:phoneNumber:)` (TurnkeySwift/TurnkeyUtils) READ IT BACK
  OUT of the token and return `(message, clientSignaturePublicKey)` — nothing is threaded by us;
  `Stamper(apiPublicKey:)` (product `TurnkeyStamper`, NOT yet linked by RainTurnkey) loads the
  matching private key and `sign(payload:format: .raw)`; `storeSession(jwt:sessionKey:)`.
  rain-api's clientSignature JSON = vendor `v1ClientSignature` shape (`publicKey, scheme:
  "CLIENT_SIGNATURE_SCHEME_API_P256", message, signature`). `TurnkeyContext.configure` keeps
  organizationId + rpId only (H4). Backend asks outstanding: /login
  doesn't revoke other sessions (we rely on invalidateExisting today → B7); passkey signup's
  adopted-account response is indistinguishable from a fresh one (want `sessionKeyAttached`,
  see H5; the "no session" ask itself was RESOLVED by the 60 s signup key); attaching an already-walleted contact → next
  login 500; errors carry no machine code (string matching); 429 has no RAIN code (propose
  RAIN_204 tooManyAttempts cross-platform).
- PR E (IN PROGRESS 2026-09-17, branch volo/feature/handle-gas-sponsorship), gas sponsorship +
  fail-closed sends on chains Turnkey cannot broadcast on — a mirror of Android's WALL-31 and its
  follow-ups (TurnkeyBroadcastChains, minimal sponsored payloads with the
  gas-station nonce, sponsored Solana sends carrying the System Program key).
  Core: `Capability.gasSponsorship`; `RainError.chainNotSupported(chainId:details:)` = RAIN_104 (was 105 until PR F compacted the map);
  `WalletProvider` gains two hooks with default impls — `requireSendSupport(chainId:)` (no-op) and
  `sponsorsFees(chainId:)` (false). `RainSdkManager` gates `withdrawCollateral` and
  `approveTokenAllowance` (after config validation, before the wallet) — estimates/reads AND
  `prepareWithdrawal` are NEVER gated (review 2026-09-21: prepare only signs, Turnkey signs on
  every chain, and the prepared params are the host's self-broadcast path for Avalanche; Android
  still gates prepare at RainSdkManager.kt:177 — flag for parity). DECISION 2026-09-17
  (diverges from Android, which quotes 0): fee estimates keep returning the REAL on-chain cost
  even when sponsored, so hosts can show the saving — flag to Android for parity. The Solana
  composers take `sponsoredFees` (skip the fee-lamport
  check and dry run — a zero-SOL wallet would false-fail — keep the rent check, and carry the
  System Program via `SolanaTransactionBuilder.extraReadonlyKeys`, which Turnkey's sponsored
  path can require). Because sponsored sends skip the dry run, a contract/program rejection
  surfaces only from Turnkey's send status AFTER signing — the adapter's
  `TurnkeyWalletProviderAdapter.sendFailure(from:)` (review 2026-09-21) maps a FAILED status
  carrying a decoded revert (`error.revertChain` / `error.eth.revertChain` / `error.solana`
  details) to `transactionSimulationFailed`, so `mapWithdrawalError` still yields
  `withdrawalRevertedByNetwork` (RAIN_405); other failures stay `providerError`. Both poll
  loops use it. Android's poll loops still throw providerError — flag for parity.
  SEND OUTCOMES (2026-10-14, parity with Android #75 / WALL-119; `TurnkeySendOutcome.swift`).
  VENDOR FACTS (swift-sdk 4.0.0, verified in source): `ethSendTransaction`/`solSendTransaction`
  submit THEN poll `get_activity` inside the call (`ActivityPollerConfig` 1 s × 3, NOT exposed
  on `TurnkeyContext`); the response types have a NON-optional `sendTransactionStatusId` that
  only exists for COMPLETED — any other ending (PENDING past the poll, FAILED, REJECTED,
  CONSENSUS_NEEDED) is decoded "as-is" into that type and throws `DecodingError`, LOSING the
  `v1Activity`. So the adapter owns the ending: `sortedSendOutcome` runs the vendor call inside
  `executeWrite` and converts every post-submit failure to an outcome (the coordinator's 401
  refresh-and-retry can only ever re-run a pre-submit failure — a 401 from the vendor's in-call
  poll is indistinguishable from a submit 401, so sends are NEVER re-submitted). Four endings:
  status id → existing status poll; accepted activity (decode failure, or 401/408/429 — the
  Swift client throws the IDENTICAL apiError for submit and in-call poll, so none of those is a
  refusal; review #44) → READ BACK from `getActivities` (newest of the type since submit − 30 s
  skew, matched on intent via `evmIntentMatcher` incl. nonce/gasStationNonce /
  `solanaIntentMatcher`) then `awaitSendActivity` polls `getActivity` ×10 (COMPLETED → status
  id; FAILED/REJECTED → providerError(`TurnkeySendActivityFailure`, reason from
  `activity.failure?.message`), never userRejected; still pending → RAIN_302 carrying the
  ACTIVITY id); refusal (other 4xx) → leaves as itself; everything else (5xx, transport,
  read-back finds nothing) → `transactionOutcomeUnknown` RAIN_305 (new core case; no cause on
  purpose). RULE (review #44): once Turnkey has accepted, EVERY failed read — activity wait,
  both status polls — ends as RAIN_302 with the id it holds (catch-all, not just tokenExpired);
  only `CancellationError` passes through (plus `Task.isCancelled` checks, since a cancelled
  URLSession throws a URL error) — and it must ALSO pass through `RainSdkManager`: every
  `catch { throw RainError.from(underlying:) }` there is preceded by
  `catch is CancellationError { throw CancellationError() }` (review #44; `from` would wrap it as
  RAIN_501 "settled"). Keep that pair on any new manager method. Same guard (+
  `Task.isCancelled`, since a cancelled URLSession throws `URLError.cancelled` → networkError)
  on `JsonRpcClient`, `PrivyRpcClient`, Portal/Privy provider resolution. FOLLOW-UP (not done):
  one SPI helper `RainError.mapping(_:) throws -> RainError` (rethrows cancellation, else
  `from`) replacing all hand-written pairs, and the 14 unguarded sites in
  `TurnkeyManagedAuth` + `RainSdk.provider` resolution (auth-tier: wrong code, no money). `TurnkeySendGate` (actor, FIFO) serialises each adapter's
  submit-and-identify phase so overlapping sends can't claim the same newest activity; the
  status poll runs outside it. RAIN_302 `statusId` may now be an activity id (doc widened).
  `TurnkeyClientProtocol` gained `getActivity`. Mock: `activityNotCompletedError(_:kind:)`
  builds the GENUINE vendor error shape. Vendor ticket to file on tkhq/swift-sdk (mirror
  kotlin-sdk#98): typed error carrying the activity + expose the poller config; when it lands,
  the read-back can go (Android deleted theirs at http 2.2.0).
  Turnkey: `TurnkeyBroadcastChains` (vendor's managed-broadcast list — EVM mainnets+testnets per
  docs.turnkey.com broadcasting page; Solana mainnet+devnet ONLY; also owns the get-balances
  chain list) — every send entry (EVM funnel `sendTransaction`, Solana funnel, both transfer
  entries) calls `requireSendSupport`. `TurnkeyConfig.sponsorGas` DEFAULTS TRUE (product
  decision: sponsorship is the product; on orgs without Gas Sponsorship enabled Turnkey rejects
  sponsored sends → pass false). Sponsored EVM body = minimal payload: no nonce/gas fields,
  `sponsor: true`, `gasStationNonce` fetched via `client.getNonces(gasStationNonce: true)` per
  send (Turnkey's one-tx-per-request guarantee needs it; nil → server-side fetch). Solana sends
  pass `sponsor`. `estimateTransactionFee` quotes the chain cost regardless. Capabilities via
  `TurnkeyWalletProviderAdapter.capabilities(sponsorGas:)`, shared by descriptor + wallet.
  `sponsorsFees` = sponsorGas && supportsSend (never sponsor an unsendable chain). RainWallet:
  `RainWalletConfig.sponsorGas` (default true), capabilities follow the backing provider.
  Tests construct adapters with `sponsorGas: false` to keep pinning the self-paid body (test
  helper default), and opt in explicitly for sponsored assertions. Known limitation (v0, both
  platforms): NO self-broadcast fallback — Avalanche (Rain's README example chain!), Celo,
  ZKsync are read-only through Turnkey until a signRawPayload + own-RPC path exists or Turnkey
  adds the chains.
  SPONSORED RENT (WALL-163, 2026-10-30, branch volo/feature/sponsored-solana-rent; twin of
  Android #83 / WALL-162, parent WALL-160). VENDOR FACT (docs.turnkey.com solana-rent-refunds):
  with the org's "Sponsor Solana Rent" switch on (Enterprise, off by default), Turnkey PRE-FUNDS
  the user signer for a created account's rent WHEN THAT SIGNER IS THE PAYER — so the bytes do
  not change and the sender must stay the ATA payer; refunded rent on a later close goes to the
  signer, not the sponsor (extraction risk; guardrails are org spend caps, and the SDK composes
  no CloseAccount). Core: `WalletProvider.sponsorsRent(chainId:)` (default false; doc: only
  consulted when `sponsorsFees` is true — core ANDs the two in `prepareSolanaWithdrawal`),
  `SolanaLamportPreflight` (NEW, shared by BOTH composers — the withdraw composer had NO lamport
  check before; fee unless sponsored + rent unless sponsored, rent READ FROM THE CLUSTER via
  `SolanaRpcClient.getMinimumBalanceForRentExemption(chainId:dataLength: 165)` — the pinned
  2_039_280 is GONE, mainnet/devnet answered 1_488_440 on 2026-10-29; no cache; Token-2022 ATAs
  are larger, the dry run catches it), `Simulation.fundsShortfall`
  (`InsufficientFundsForFee|ForRent` in the error) → `insufficientFunds` RAIN_402 in both
  composers where a dry-run refusal used to be RAIN_403/405 — cross-platform contract change,
  Android #83 made the same move. `buildPreparedWithdrawal(selfPaid:)`: `prepareWithdrawal`
  passes true (host submits AND pays — every check runs as unsponsored; was provider-driven on
  iOS, Android already passed false/false), `withdrawCollateral` false. Turnkey:
  `TurnkeyConfig.sponsorRent` (default false, both inits), adapter `sponsorsRent` =
  `sponsorRent && isSolana && sponsorsFees(chainId)`, SPL send passes both flags;
  `sendFailure` classifies a Solana shortfall FIRST (`transactionErrorJson` InsufficientFunds*,
  or a log line matching `^Transfer: insufficient lamports (\d+), need (\d+)$` — the System
  Program's `ic_msg`, no "Program log:" prefix — with amounts). RainWallet passes
  `sponsorRent: true` ALWAYS (Rain's switch, partner can't see it; a flip reaches installed
  apps without a release; until the switch is on, a 0-SOL first-time-recipient send fails after
  signing as RAIN_402). Test seams: `TestManagers.turnkeyManager(sponsorRent:)`, mock
  `.solanaLamportShortfall(transactionErrorJson:logs:)`, stub `getMinimumBalanceForRentExemption`
  with a bare number (default "0x0" fallback fails the parse). Device validation pending the
  sandbox org switch, like Android.
- PR G (IN PROGRESS 2026-09-23, branch volo/refactor/apply-platform-parity-changes), RainWallet
  host-facing PARITY with Android (ticket list, all v5 clean breaks, no typealiases):
  `RainSDKError` → `RainError` (file `Core/RainError.swift`); `internalLogicError` →
  `internalError`; `errorCode` → `code`; `unauthorized` / `walletUnavailable` /
  `withdrawalRevertedByNetwork` gained `details:` (defaulted, so bare `.walletUnavailable()`
  still works; equality ignores payloads). `ProviderDescriptor.close()` (no-op default);
  `RainSdk.close()` TERMINAL (reset + close descriptors; provider/first/tokenMetadata/
  registerTokens → sdkNotInitialized after); `Builder.build()` closes descriptors replaced by a
  re-register of the same id (a COPY of the live value is skipped — descriptors are structs, so
  identity = same type + identical `ObjectIdentifier`s of class-typed children via `Mirror`). `RainProvider.close()` TERMINAL (auth/export
  → invalidConfig, `currentAuthState()` → .unauthenticated, hasActiveSession false; sessionState
  keeps reporting the process-wide backend). Capabilities: Turnkey/Rain = `[.export, .multiChain,
  +.gasSponsorship]` — `.biometricGate` DROPPED (vendor enclave key `authPolicy: .none`, nothing
  gates signing). RainWallet: `authState` is now the PUBLISHER + `currentAuthState()` (mirrors
  sessionState/currentSessionState; Turnkey SPI + controller renamed the same way);
  `RainWalletConfig.walletAddress` REMOVED; `refreshExpirationSeconds` is `Int?` on both
  RainWallet and Turnkey policies (String only at the vendor call); `RainWalletSessionPolicy`
  init PRECONDITIONS (non-negative, positive TTL, maxRetryDelay >= initialRetryDelay);
  `.active(expiresAtEpochSeconds:)`. Core: `registerTokens` is `async throws` everywhere
  (RainSdk, RainClient, manager) and every register path (incl. Builder at build()) runs
  `TokenInfoValidation` (EVM `0x`+40 hex with EIP-55 when mixed-case, Solana base58 32 bytes,
  decimals 0...77, whole list first); `TokenMetadataStore.resolvedTokenInfo/decimals` THROW
  invalidConfig on chain decimals outside 0...77 (never cached); `RainSdk.tokenMetadata` `async
  throws` — invalidConfig for no RPC endpoint / malformed address / out-of-range decimals, nil
  reserved for "could not establish". DELETED: `generateWalletAddressQRCode`, `Deprecated.swift`
  (all 1.x shims), Portal `DeprecatedAPITests`. `getTokenAllowance(chainId:contractAddress:
  spender:owner:)` (owner last, like confirmTokenAllowance + Android). confirmTokenAllowance
  doc: lapsed window = `transactionPending`, not networkError.
- PR F (DONE 2026-09-22, merged as #40), Rain API out of
  the SDK — see the RainCore bullet above. Deleted: `Services/RainApi/*`, `RainApiEnvironment`,
  `RainCollateralContract`, `RainSdk.fetchCollateralContracts/fetchCollateralContract/
  fetchAdminSignature/configureRainApi/isRainApiConfigured`, builder `rainApiEnvironment(_:)` /
  `rainApiCredentials(apiKey:userId:)`, error cases `rainApiNotConfigured` / `signatureNotReady` /
  `noCollateralContracts`, `RainAuthPullChains.supported(for:)/isSupported(chainId:in:)` (now an
  internal `supported(for: Kind)`). Android has NOT done this yet — iOS leads; flag for parity.
