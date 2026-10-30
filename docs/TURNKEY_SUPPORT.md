# Turnkey Support

Rain SDK for iOS supports [Turnkey](https://turnkey.com) as a wallet provider, alongside the Portal MPC and Privy adapters. Turnkey ships as the `TurnkeyProvider` adapter in its own `rain-turnkey-ios` module (`RainTurnkey`), like the other providers. Authentication is bring-your-own: the host app uses the official [Turnkey Swift SDK](https://docs.turnkey.com/sdks/swift/getting-started) to authenticate (passkeys, OAuth, OTP, auth proxy) and hands the live `TurnkeyContext` to Rain via `TurnkeyConfig(turnkey:)`. SDK-owned email-OTP authentication exists behind `@_spi(RainWallet)` and ships to hosts exclusively through the Rain-branded `RainWallet` module.

## Requirements

- iOS 17.0+ (Rain SDK's platform floor; Turnkey's Swift SDK requires iOS 16+, so Rain's floor governs).
- Swift 6.1+ / Xcode 16.3+.
- Turnkey Swift SDK initialized and authenticated by the host app (passkey / auth-proxy / OAuth / OTP flow completed) before the `TurnkeyContext` is handed to Rain.

## Adding the dependency

Link the `rain-turnkey-ios` product and `import RainTurnkey` (which re-exports `RainCore`). The Turnkey vendor products ship transitively with it. Internally Rain pins:

```
https://github.com/tkhq/swift-sdk.git (exact 4.0.0)
  products: TurnkeySwift, TurnkeyHttp, TurnkeyTypes
```

## Architectural split

Rain SDK's public Turnkey surface is exactly one boundary: registering a `TurnkeyProvider(TurnkeyConfig(turnkey:walletAddress:))` with the `RainSdk` builder, then resolving `rain.provider(.turnkey)`. Everything *before* that (`TurnkeyContext` setup, OTP/passkey/OAuth flows, sub-org provisioning, wallet creation) is host-app code, written against Turnkey's own Swift SDK. This split keeps Rain free of Turnkey's auth-UI surface.

| Layer | Who owns it | Examples |
|---|---|---|
| Authentication (pre-register) | Your app | Turnkey Swift SDK: proxy middleware, passkey registration, OTP / OAuth login, `createWallet` |
| Hand-off | Boundary | `RainSdk.builder().register(TurnkeyProvider(TurnkeyConfig(turnkey: context, …)))` → `rain.provider(.turnkey)` |
| Wallet operations (post-resolve) | Rain SDK | `client.getWalletAddress()`, `getBalance(chainId:token:)`, `sendNative(...)`, `withdrawCollateral(...)` |

Turnkey's Swift guides for the pre-register half:

- Proxy middleware: `https://docs.turnkey.com/sdks/swift/proxy-middleware`
- Passkeys: `https://docs.turnkey.com/sdks/swift/register-passkey`

## Reference glue (example app)

The example app's `RainSDKService.swift` (`Example/RainSDKDemo/RainSDKDemo/Core/Services/RainSDKService.swift`) shows the full hand-off: it accepts a `TurnkeyContext` whose `authState == .authenticated`, builds the SDK, and resolves the client:

```swift
import RainTurnkey   // re-exports RainCore
import TurnkeySwift

let rain = try RainSdk.builder()
    .rpcEndpoints([
        43114: "https://avalanche-c-chain-rpc.publicnode.com",
        43113: "https://avalanche-fuji-c-chain-rpc.publicnode.com"
    ])
    .register(
        TurnkeyProvider(
            TurnkeyConfig(
                turnkey: turnkeyContext,
                walletAddress: nil // omit to use the first Ethereum account from the context
            )
        )
    )
    .build()

let client = try await rain.provider(.turnkey)
```

`rain.provider(_:)` is `async`: resolving the Turnkey provider probes the Turnkey wallet list (refreshing it once if needed) and throws `RainError.walletUnavailable` if no usable Ethereum account is available. You can register other adapters (e.g. `PortalProvider`, `PrivyProvider`) on the same builder and resolve each independently; providers do not replace one another.

### Host contract for the `TurnkeyContext`

`TurnkeyConfig` is `@unchecked Sendable` because `TurnkeyContext` is a host-owned reference type with mutable published state that Rain reads from arbitrary executors. The contract: finish authentication **before** handing the context to Rain, and don't mutate it (re-auth, logout, wallet switch) while Rain calls are in flight; after such changes, build a new `RainSdk` or re-resolve the provider.

## What Rain uses Turnkey for

After the Turnkey-backed `client` is resolved, every wallet operation routes through Turnkey:

| Rain operation | Turnkey API used |
|----------------|------------------|
| `client.getWalletAddress()` | `TurnkeyContext.wallets` (first Ethereum-format account; cached after first resolve) |
| `client.getWalletAddress(chainId:)` (Solana sentinel ids) | `TurnkeyContext.wallets` (first Solana-format account, base58) |
| `client.getBalance(chainId:, token: .native)` | `getWalletAddressBalances` (CAIP-19 `slip44:` filter) on supported chains; RPC `eth_getBalance` otherwise |
| `client.getBalance(chainId:, token: .contract(...))` | RPC `eth_call` (`balanceOf`) via the shared chain reader |
| `client.getTokenBalances(chainId:)` | `getWalletAddressBalances` (CAIP-19) on supported chains; Multicall3 / parallel `eth_call` otherwise |
| `client.sendNative(...)` / `client.sendToken(...)` (EVM) | `ethSendTransaction` + `getSendTransactionStatus` polling |
| `client.sendNative(...)` (Solana) | `solSendTransaction` + status polling, with an RPC signature-recovery fallback |
| `client.withdrawCollateral(...)` | `TurnkeyContext.signRawPayload` (EIP-712) + `ethSendTransaction` |
| `client.getTransactions(...)` | `getActivities` (filtered to `ACTIVITY_TYPE_ETH_SEND_TRANSACTION`, or `ACTIVITY_TYPE_SOL_SEND_TRANSACTION` on Solana ids) |
| `client.estimateGas(...)` / `estimateWithdrawalFee(...)` | RPC `eth_estimateGas` + `eth_gasPrice` (exact `BigUInt`/`Decimal` math) |

Chains covered by Turnkey's `get-balances` API (Ethereum, Sepolia, Base, Base Sepolia, Polygon, Polygon Amoy, plus Solana clusters) read balances through Turnkey; any other configured chain falls through to Rain's chain reader over your RPC endpoints.

## Which chains can send

Turnkey's `ethSendTransaction` / `solSendTransaction` are the SDK's only send path on this
provider, and they exist solely on Turnkey's managed-broadcast networks: Ethereum, Base, Polygon,
Arbitrum, Optimism, BNB Chain, Monad, Tempo, Robinhood Chain (mainnets and their testnets), and
Solana mainnet + devnet. The full list lives in `TurnkeyBroadcastChains` and follows
[Turnkey's broadcasting docs](https://docs.turnkey.com/features/transaction-management/broadcasting).
A send on any other chain — Avalanche, Celo, ZKsync, Solana testnet — fails closed with
`RainError.chainNotSupported` (`RAIN_104`) **before** any contract read or signing prompt:
`sendNative`, `sendToken`, `withdrawCollateral` and `approveTokenAllowance` all check the gate
first. Reads and signing are not gated: balances, history, fee estimates and `prepareWithdrawal`
work on every chain with an RPC endpoint registered — Turnkey signs anywhere, it just cannot
broadcast there. A host that needs Avalanche today can therefore `prepareWithdrawal` and submit
the returned transaction parameters through its own RPC.

## Gas sponsorship

`TurnkeyConfig(sponsorGas:)` defaults to **true**: every send on a broadcast chain is
fee-sponsored by Turnkey's Gas Station — transfers, collateral withdrawals, Auth Pull approvals
and raw `sendTransaction` calls alike. The user needs no native gas token; the cost passes
through to the partner. `estimateGas` / `estimateWithdrawalFee` still quote the on-chain cost
the send would have — deliberately, so a host can show the user what sponsorship saves them.
Sponsored sends are minimal payloads —
Turnkey builds the outer transaction, so the SDK pins no nonce or gas quote; replay protection
is Turnkey's gas-station nonce, fetched per send. Solana sends are sponsored too, network fee
only: the fee check and dry run are skipped, and the rent of a first-time recipient's token
account follows `sponsorRent` (below).

Sponsorship must be enabled on the Turnkey organization (Enterprise feature, dashboard); on an
organization where it is not, Turnkey rejects sponsored sends — pass `sponsorGas: false` there,
and the wallet pays its own fees with the SDK's own nonce/gas quoting. With `sponsorGas` on the
provider advertises `Capability.gasSponsorship`.

### Solana rent

The first transfer of a token to someone who has never held it creates their token account, and
that account needs a rent-exempt deposit. Who pays it is Turnkey's separate "Sponsor Solana Rent"
switch (Enterprise plans, off by default). `TurnkeyConfig(sponsorRent:)` tells the SDK what that
switch says, and defaults to false like the switch. With it off, the SDK reads the deposit from
the cluster (`getMinimumBalanceForRentExemption` for a 165-byte account; about 0.0015 SOL in
late 2026) and refuses the send with `insufficientFunds` before signing when the sender cannot
cover it. With it on, and `sponsorGas` on, the rent check is skipped: Turnkey pre-funds the
payer inside the sponsored send. The transaction itself does not change, and the sender must
stay the created account's payer — that is the condition under which Turnkey pre-funds. Rent is
never sponsored without the fee, because Turnkey only pre-funds inside a sponsored send.

If `sponsorRent` is on but the organization's switch is off, a sender holding no SOL gets a
signed send that fails at the backend; the adapter maps the runtime's `InsufficientFundsForRent`
or the System Program's `Transfer: insufficient lamports <held>, need <needed>` log line to
`insufficientFunds` (RAIN_402) with the amounts, instead of a generic failure. A self-paid dry
run the runtime refuses for a fee or rent shortfall is `insufficientFunds` too, where it used to
surface as a simulation failure.

Two things to know before turning the switch on. Refunded rent follows Solana's rules: when a
sponsored account is later closed, the deposit goes to the account's owner or the signer, not back
to the sponsor — and a user who exports their key can close accounts themselves, so the real
guardrails are spend caps and monitoring on the organization (Turnkey's rent-sponsorship page
covers this). And the SDK composes no `CloseAccount` instruction, which keeps the common leakage
path out of its own sends.

`RainWalletConfig` has no rent parameter: the Rain wallet passes `sponsorRent: true` always,
because whether rent is funded is Rain's switch, which a partner can neither see nor set, and a
flip has to reach installed apps without a release.

## After a send is accepted

Every send — `sendNative`, `sendToken`, `withdrawCollateral`, `approveTokenAllowance`, raw
`sendTransaction`, EVM or Solana — goes through Turnkey's `ethSendTransaction` /
`solSendTransaction`. Those vendor calls submit the activity and then **poll it inside the call**
(`ActivityPollerConfig`, 1 s × 3 by default; the Swift SDK does not expose it on `TurnkeyContext`,
so the SDK cannot widen it). Their response types carry a non-optional `sendTransactionStatusId`
that only exists once the activity is `COMPLETED`; for any other ending the vendor decodes the
raw activity into that type, the key is missing, and the call throws a `DecodingError` that has
lost the activity (swift-sdk 4.0.0, verified). Left alone, a slow sponsored send would look like
a generic failure with nothing to resume from — and a 401 from the vendor's in-call poll would be
indistinguishable from a 401 on the submit, so a plain refresh-and-retry could submit twice.

The adapter therefore owns the ending. After the submit a send has exactly four:

1. **A status id** — the activity completed inside the vendor's poll. The adapter polls
   `get_send_transaction_status` for the hash (EVM) or signature (Solana), up to 30 s. A
   `FAILED` status carrying a decoded revert is `withdrawalRevertedByNetwork` / `RAIN_405` on a
   withdrawal (`providerError` elsewhere); a poll that runs out is `transactionPending` /
   `RAIN_302` carrying the **status id**. So is a status *read* that fails for good — the
   session dying, a dropped connection, a 5xx past the coordinator's retries: Turnkey has the
   transaction, only our view of it stopped.
2. **An accepted activity** — the vendor threw its decode failure, or answered 401, 408 or
   429, after Turnkey accepted the activity (the Swift client throws the identical error for
   the submit and for its in-call poll, so none of those can be read as a refusal). The adapter
   reads the activity back from the activity log (newest `ETH_SEND_TRANSACTION` /
   `SOL_SEND_TRANSACTION` created since the submit, matched on the intent: `from` + `to` +
   calldata + value + the account or gas-station nonce, or signer + cluster + the unsigned
   transaction) and waits on it by id with `get_activity` — ten reads, one per second.
   `COMPLETED` joins ending 1; `FAILED` / `REJECTED` is `providerError` / `RAIN_501` carrying
   Turnkey's reason (never `userRejected`); still executing after the budget is
   `transactionPending` / `RAIN_302` carrying the **activity id** — no SDK call takes it, but
   it equals `uniqueId` on the history row for the send. Any read that fails mid-wait ends the
   same way, with the activity id.
3. **A refusal** — Turnkey answered the submit with a 4xx other than 401 / 408 / 429. Nothing
   was executed; the error leaves as itself and maps as usual (403 → `unauthorized`, …).
4. **Unknown fate** — a 5xx to the submit, a transport failure, an undecodable answer, or an
   accepted-activity read-back that finds nothing. The send may still land, and there is no
   identifier to resume from: `transactionOutcomeUnknown` / `RAIN_305`. It carries no cause on
   purpose, so no layer above can read an HTTP status off it and retry. Read history or the
   balance before sending again.

What this guarantees a host: **the SDK never submits a send twice.** A 401 on a send is not
refreshed-and-retried (unlike signing, where it is): the activity is read back instead, and if
nothing is found the ending is `RAIN_305` rather than a second activity. `RAIN_501` from a
Turnkey send therefore always means *settled, nothing moved*. Sends on one provider are
serialised through their submit-and-identify phase (a small per-adapter gate), so two
overlapping sends cannot both read back the same "newest" activity; the 30 s status poll runs
outside the gate. Cancelling the task that called the send surfaces `CancellationError` at
every stage, never an outcome — but the send may already have gone out, so a host that cancels
should treat it like `RAIN_305`.

Same four endings and codes as rain-sdk-android. Android takes the activity from the Kotlin
client's typed `ActivityNotCompleted` error (http 2.2.0); the Swift client has no equivalent
yet, hence the read-back. Vendor request filed: throw a typed error carrying the `v1Activity`
for non-completed statuses and expose `ActivityPollerConfig` on `TurnkeyContext`.

## Solana notes

The Turnkey adapter is the SDK's multi-chain provider (it advertises `.multiChain`): Solana sentinel chain ids (`RainChain.solanaMainnet` 900 / `solanaDevnet` 901 / `solanaTestnet` 902) route `getWalletAddress(chainId:)`, balances, `sendNative`, `sendToken`, `withdrawCollateral`, and `getTransactions` to the Turnkey Solana account.

- Native SOL and SPL token transfers are both supported end to end. Composition and every preflight live in core's `SolanaTransferComposer` (shared with the Privy adapter, so the two cannot drift); the provider only signs and broadcasts. For an SPL transfer that means: recipient validated as a wallet (not a token account or mint), mint resolved on chain for its decimals and owning token program (classic SPL Token or Token-2022), sender's associated token account derived and checked for balance, recipient's account created in the same transaction when missing (`CreateIdempotent`; its rent, read from the cluster, is demanded from the sender unless sponsored — see *Solana rent* above), SOL-for-fees checked, and the whole thing dry-run with `simulateTransaction` before it is handed over for signing.
- Token-transfer failures surface as their own errors — `tokenNotFound`, `tokenAccountNotFound`, `insufficientTokenBalance`, `invalidRecipient` — which reuse existing `RAIN_*` codes so the code map stays identical to Android's.
- SPL balances come from Turnkey's `get-balances` where it indexes the cluster. Where it doesn't (devnet in particular, where Turnkey answers with SOL only or errors), `getTokenBalances` discovers the wallet's holdings from the node instead: `getTokenAccountsByOwner` against both token programs, summed per mint. Solana has no token registry, so nothing has to be registered up front — but symbol / name stay `nil` unless the mint is registered, since that metadata lives off chain (Metaplex).
- `getTransactions` is sourced from Turnkey's activity log (`ACTIVITY_TYPE_SOL_SEND_TRANSACTION`), matching the EVM path: it lists only what this wallet sent through Turnkey — no receives — and the row's hash is the Turnkey status id, not an explorer-resolvable signature. Both transfer shapes are decoded out of the activity's unsigned transaction: a System transfer becomes a native row (`category: "external"`, `asset: "SOL"`), an SPL `TransferChecked` a token row (`category: "token"`, mint + raw amount + decimals in `rawContract`, `asset` only when the mint is registered — Solana keeps symbols off chain). An SPL transfer's recipient is a token account, so the wallet behind it comes from the transaction's account-creation instruction when present and from one `getAccountInfo` otherwise; if neither resolves, the token account itself is reported rather than dropping the row.
- Turnkey's API hex-decodes the `unsignedTransaction` field (despite the type documenting base64), so Rain serializes the transfer message as hex.
- Turnkey returns a send-status id rather than an on-chain signature; Rain polls the status for the signature and, as a defensive fallback, recovers it from the chain via `getSignaturesForAddress`. That applies to `sendNative` / `sendToken` return values — history rows always carry the status id, since the activity log has no signature. A send the vendor's own poll gives up on first is read back and waited on by activity id — see [After a send is accepted](#after-a-send-is-accepted).
- **Collateral withdrawal** works on Solana too. Rain's collateral program authorizes a withdrawal differently from the EVM contracts: instead of EIP-712 calldata, the coordinator executor signs a keccak-encoded withdraw message off chain (that is the admin signature the Rain API returns). Core composes a two-instruction transaction — a native ed25519-program instruction proving the executor signed that exact message, then the program's `withdraw_single_signer_collateral_asset` — reading the collateral account, its coordinator's executors, and the mint's token program from the chain, and deriving the collateral-authority PDA and associated token accounts locally. It simulates the result and hands the bytes to the adapter, which signs them **as-is**: re-serializing would invalidate the embedded signature. `withdrawCollateral`'s `proxyAddress` is the collateral account and `tokenAddress` is the SPL mint; only single-signer collateral is supported.

## Signing

EIP-712 signing uses `TurnkeyContext.signRawPayload` with `.payload_encoding_eip712` + `.hash_function_no_op`. Rain normalizes the returned `r`, `s`, `v` components into a `0x`-prefixed 65-byte hex signature compatible with `eth_signTypedData_v4` responses (recovery id auto-adjusted to the 27/28 range when needed).

## Accessing the Turnkey instance

Rain exposes no vendor getters (core references no concrete vendor type). You already own the `TurnkeyContext` (it's the instance you authenticated and passed to `TurnkeyConfig`), so keep your own reference for advanced Turnkey operations (export, session management, extra wallets).

## Error handling

Turnkey-specific errors are mapped into the standard `RainError` hierarchy (see `RainError+Mapping.swift` in `RainCore`):

| Turnkey error | Mapped to |
|---------------|-----------|
| `TurnkeySwiftError.invalidSession` | `RainError.tokenExpired` |
| `TurnkeyRequestError.apiError` with HTTP 401 | `RainError.tokenExpired` |
| `TurnkeyRequestError.apiError` with HTTP 403 | `RainError.unauthorized` |
| `TurnkeyRequestError.network` | `RainError.networkError` (reads); on a send, any failure after the submit is `RainError.transactionOutcomeUnknown` — see [After a send is accepted](#after-a-send-is-accepted) |
| `DecodingError` from `ethSendTransaction` / `solSendTransaction` | The activity was accepted but not `COMPLETED` within the vendor's poll; read back and waited on — see [After a send is accepted](#after-a-send-is-accepted) |
| Config / setup errors (`invalidConfiguration`, `missingAuthProxyConfiguration`, `invalidRefreshTTL`, `publicKeyMissing`, `signingNotSupported`, `invalidJWT`, `invalidResponse`, `keyAlreadyExists`, `keyNotFound`, `keyIndexFailed`, `keychainAddFailed`, `oauthInvalidURL`, `oauthMissingIDToken`) | `RainError.internalError` |
| Wrapper errors (`failedToSignPayload`, `failedToFetchWallets`, …) | Unwrapped recursively; e.g. a wrapped `ASAuthorizationError.canceled` (passkey prompt dismissed) surfaces as `RainError.userRejected` |
| Anything else | `RainError.providerError` |

Network errors raised during direct RPC calls (balances, fee estimation) surface as `RainError.networkError`.

## Session expiry, refresh, and retry

Turnkey sessions are short-lived JWTs (15 minutes by default) that die silently once expired.
Rain hardens every Turnkey-backed call against this, controlled by `TurnkeySessionPolicy`:

```swift
TurnkeyProvider(
  TurnkeyConfig(
    turnkey: turnkeyContext,
    sessionPolicy: TurnkeySessionPolicy(
      refreshBufferSeconds: 60,        // refresh when < 60s of lifetime remain
      autoRefresh: true,               // let Rain call Turnkey's refreshSession itself
      refreshExpirationSeconds: nil,   // TTL for refreshed sessions (nil = Turnkey default)
      maxTransientRetries: 2,          // backoff retries for 5xx/429/network on reads
      initialRetryDelay: 0.5,
      maxRetryDelay: 4
    ),
    onSessionExpired: {
      // Re-auth hook: the session died and could not be refreshed. Fired once per
      // session death, off the main thread. Route the user back to login.
    }
  )
)
```

What every wallet call now does:

1. **Expiry check** — the session's JWT `exp` is checked before the request. An
   already-expired session throws `RainError.tokenExpired` (or is refreshed first, see
   below) instead of burning a round-trip on a guaranteed 401.
2. **Proactive refresh** — with `autoRefresh` on (the default), a session expired or inside
   `refreshBufferSeconds` of expiry is refreshed through Turnkey's `refreshSession` before the
   call. Refreshes are single-flighted: concurrent calls share one refresh. A proactive
   refresh that fails for a non-auth reason (a network blip) proceeds on the current session
   while it is still valid; only Turnkey rejecting the refresh, or a session already past
   `exp`, is treated as a death.
3. **Refresh-on-401** — a read or a signing call rejected with HTTP 401 / `invalidSession` is
   refreshed and retried exactly once (a 401 there means Turnkey rejected the request before
   executing it). A second 401 surfaces as `RainError.tokenExpired`. **Sends are the exception**:
   the vendor's send call polls inside the call, so a 401 may follow an accepted submit; a send
   is never re-run — see [After a send is accepted](#after-a-send-is-accepted).
4. **Transient backoff** — idempotent reads (balances, history, transaction-status polls)
   retry HTTP 5xx/429/408 and network failures with exponential backoff. Sends and signing
   are never retried on transient failures.
5. **Re-auth hook** — when the session dies for good (refresh rejected, or Turnkey's own expiry
   timer cleared it while the app was idle), `onSessionExpired` fires once — even with no Rain
   call in flight, via a passive watcher over Turnkey's auth state.

With `autoRefresh: false` Rain never touches the session: expired sessions and 401s surface
as `RainError.tokenExpired` immediately and refresh/re-auth is entirely the host's job.

### Observing session state

`TurnkeyProvider` exposes the session as seen at the Rain boundary:

```swift
let provider = TurnkeyProvider(TurnkeyConfig(turnkey: turnkeyContext))

provider.currentSessionState()  // .loading | .active(expiresAtEpochSeconds:) | .expired | .unauthenticated

let cancellable = provider.sessionState.sink { state in
  if state == .expired || state == .unauthenticated {
    // show re-login UI
  }
}

try await provider.refreshSession()  // manual refresh; throws .tokenExpired when it fails
```

`sessionState` emits on every Turnkey auth/session change and additionally re-checks when an
active session passes its expiry instant, so a silent death is observable without polling.

When `onSessionExpired` is set, resolving the provider starts a passive watcher over the
process-wide Turnkey singleton. A host that rebuilds the SDK per login should call
`provider.close()` on the provider it is discarding so a stale watcher cannot fire.

Reference: the example app's `RainSDKService.swift`, `WalletSessionStatus.swift` and `HomeView`'s
session card.

## Registering alongside Portal or Privy

Adapters are not mutually exclusive. Register several on the same builder and resolve each to its own `RainClient`: one SDK instance, independent provider-bound clients:

```swift
import RainPortal
import RainTurnkey

let rain = try RainSdk.builder()
    .rpcEndpoints(endpoints)
    .register(PortalProvider(PortalConfig(sessionToken: portalSessionToken)))
    .register(TurnkeyProvider(TurnkeyConfig(turnkey: turnkeyContext)))
    .build()

let portalClient = try await rain.provider(.portal)
let turnkeyClient = try await rain.provider(.turnkey)
```

Each client is bound to its provider for its lifetime; there is no "active provider" to swap.

## iOS-specific integration notes

- **Turnkey ships as its own product.** Like Portal and Privy, the adapter lives in `rain-turnkey-ios` — linking `rain-core-ios` (or another provider's product) never pulls Turnkey's Swift SDK.
- **No dependency conflicts to work around.** Android needs a Bouncy Castle exclusion (Turnkey's and web3j's crypto artifacts collide); the iOS package graph has no equivalent duplicate-symbol issue. The only packaging quirk is a SwiftPM warning about two `secp256k1.swift` forks (from `Web3.swift` and `web3swift`) resolving to the same package identity; it is a warning today and requires no consumer action.
- **Fail-fast resolution.** `TurnkeyProvider.create(context:)` probes the wallet (`address()`) so an unusable context fails at `rain.provider(.turnkey)` time rather than on the first business call.
