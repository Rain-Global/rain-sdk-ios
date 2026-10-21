# Rain SDK for iOS: Method Reference

Reference for the Rain SDK public API. The SDK is **modular**: `rain-core-ios` (`RainCore`) carries
the vendor-free port, registry, and domain logic; each wallet provider ships as its own adapter
(`TurnkeyProvider`, `PortalProvider`, `PrivyProvider`). You
assemble a `RainSdk` with a builder, register the provider adapters your app ships, then resolve a
`RainClient` per provider.

```swift
import RainPortal   // each adapter re-exports RainCore

let rain = try RainSdk.builder()
    .rpcEndpoints([43114: "https://avalanche-c-chain-rpc.publicnode.com"])
    .register(PortalProvider(PortalConfig(sessionToken: sessionToken)))
    .build()

let client = try await rain.provider(.portal)  // async: RainClient for wallet operations
// Wallet-agnostic transaction building lives on `rain` itself, no provider required.
```

There is no singleton and no `initialize*` methods: a `RainClient` is bound to one provider for
its lifetime. See [TURNKEY_SUPPORT.md](TURNKEY_SUPPORT.md) for the Turnkey adapter walkthrough, and
[AUTH_PULL.md](AUTH_PULL.md) for the Auth Pull approval flow end to end.

---

## RainSdk

Entry point. Built via `RainSdk.builder()`; the host registers exactly the provider adapters it
ships and the chains it talks to. Nothing here references a concrete vendor type: a provider whose
module isn't linked simply can't be registered.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `providerIds` | `Set<ProviderId>` | Ids of every provider the host registered. |
| `providers` | `[any ProviderDescriptor]` | The registered provider descriptors (registration order), for capability resolution. |
| `authPullChainIds` | `Set<Int>` | Chains Auth Pull is enabled on for this instance: the configured `RainAuthPullConfig`'s chains intersected with the chains that have an RPC endpoint. Empty when no `authPullConfig(_:)` was supplied. Also exposed on `RainClient`; see [authPullChainIds](#authpullchainids). |

### Methods

#### builder() -> Builder

Starts a new `Builder`.

#### provider(_ id: ProviderId) async throws -> RainClient

Resolves the `RainClient` backed by the provider registered under `id`, materializing the vendor
wallet on first access and caching it thereafter.

- **Returns:** `RainClient` bound to that provider.
- **Throws:** `RainError.providerNotRegistered` if no provider was registered for `id`.
- **Async:** Yes (materializes the vendor wallet; e.g. Turnkey probes its wallet list).

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `ProviderId` | The id the provider was registered under (e.g. `.portal`). |

#### first(where:) async throws -> RainClient

Resolves the first registered provider (in registration order) matching the predicate (e.g. by
capability) and returns its `RainClient`.

```swift
let exporter = try await rain.first { $0.capabilities.contains(.export) }
```

- **Returns:** `RainClient` for the first matching provider.
- **Throws:** `RainError.providerNotRegistered` if no registered provider matches.
- **Async:** Yes.

| Parameter | Type | Description |
|-----------|------|-------------|
| `predicate` | `(any ProviderDescriptor) -> Bool` | Match tested against each registered provider descriptor. |

#### reset()

Tears down all resolved clients. Idempotent.

The configuration (network configs, descriptors, token store) is immutable state fixed at
`build()`, so the instance stays usable: the next `provider(_:)` / `first(where:)` call re-resolves
the provider from scratch. Build a new `RainSdk` via `builder()` to change configuration. Android's
`RainSdk.reset()` has the same contract.

- **Async:** No

#### close()

Full teardown: `reset()`, then `close()` on every registered provider descriptor so vendor
clients and session watchers stop and no `onSessionExpired` hook can fire again. Idempotent.

Terminal, unlike `reset()`: `provider(_:)`, `first(where:)`, `tokenMetadata` and
`registerTokens` throw `RainError.sdkNotInitialized` afterwards. Build a new `RainSdk` for the
next login. Same contract as Android's `RainSdk.close()`.

- **Async:** No

#### registerTokens(_ tokens: [TokenInfo]) async throws

Registers additional tokens on the live token store so their metadata (decimals / symbol / name)
resolves without an on-chain lookup. Entries are stored before the call returns, so a
register-then-query is ordered. The whole list is validated first — EVM address `0x` + 40 hex
with a correct EIP-55 checksum when mixed-case, Solana mint base58 decoding to 32 bytes, decimals
in `0...77` — and one bad entry registers nothing. Built-in registry tokens are trusted and
cannot be overridden: a registration naming one is ignored with a warning. Also available on the
builder (`Builder.registerTokens`, validated at `build()`).

- **Throws:** `RainError.invalidConfig` on a malformed entry; `sdkNotInitialized` after `close()`.

---

### Wallet-agnostic transaction building

These methods need no resolved provider: they work with any wallet or backend, backed only by
the configured RPC endpoints.

#### getLatestNonce(chainId:proxyAddress:) async throws -> BigUInt

Reads the collateral's current admin nonce — the value `buildEIP712Message` binds when `nonce` is
omitted.

#### isCollateralAdmin(chainId:proxyAddress:walletAddress:) async -> Bool?

Whether `walletAddress` is an admin of the collateral. Returns `nil` when the check could not run
(RPC failure, or a collateral exposing no `isAdmin`) — treat `nil` as unknown and proceed, never as
"not authorized".

#### buildEIP712Message(chainId:walletAddress:addresses:amount:decimals:nonce:) async throws -> RainEIP712Message

Builds the EIP-712 message the wallet signs to authorize a withdrawal, along with the salt bound
into it.

- **Returns:** `RainEIP712Message` — `message` (typed-data JSON), `salt` (32 raw bytes), and
  `saltHex`. Feed `salt` straight back into `buildWithdrawTransactionData`; a re-generated salt
  would not match the signature.
- **Throws:** `RainError` if message construction fails or inputs are invalid.

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. |
| `walletAddress` | `String` | User wallet address (used as `user` in EIP-712). |
| `addresses` | `RainWithdrawAddresses` | Proxy, controller, token, recipient addresses. |
| `amount` | `Decimal` | Amount in human-readable token units. |
| `decimals` | `Int` | Token decimals. |
| `nonce` | `BigUInt?` | Optional; if `nil`, SDK reads it from the contract. |

#### buildWithdrawTransactionData(addresses:amount:decimals:executorSignature:walletSalt:walletSignature:) throws -> String

ABI-encodes the `withdrawAsset` call for the collateral controller. Pure encoding — no RPC, so it
needs no chain ID and cannot fail on the network.

Two distinct salt/signature pairs go in, and the contract names them differently from Rain's API:
`executorSignature` (Rain's admin withdrawal signature, fetched by the host from the Rain API) encodes into `_executorPublisherSalt` /
`_executorPublisherSignature`, while the wallet's own pair encodes into `_adminSalts` /
`_adminSignatures` — the wallet is an admin of the collateral.

- **Returns:** `String`: hex-encoded calldata (e.g. `"0x..."`).
- **Throws:** `RainError` if ABI encoding or validation fails.

| Parameter | Type | Description |
|-----------|------|-------------|
| `addresses` | `RainWithdrawAddresses` | Proxy, controller, token, recipient addresses. |
| `amount` | `Decimal` | Amount in human-readable token units. |
| `decimals` | `Int` | Token decimals. |
| `executorSignature` | `RainAdminSignature` | Rain's authorization (salt, signature, expiresAt). |
| `walletSalt` | `Data` | `RainEIP712Message.salt`, unchanged (32 bytes). |
| `walletSignature` | `String` | The wallet's hex signature over the EIP-712 message (65 bytes). |

#### buildTransactionParameters(walletAddress:contractAddress:transactionData:) -> RainTransactionParameters

Composes a wallet-agnostic transaction parameter bag for a contract call. Pure helper: returns a
Rain-owned `RainTransactionParameters` struct with `value` pre-set to `"0x0"`. Hosts can hand the
result to any provider for signing / broadcast.

| Parameter | Type | Description |
|-----------|------|-------------|
| `walletAddress` | `String` | Sender wallet address. |
| `contractAddress` | `String` | Target contract address. |
| `transactionData` | `String` | Hex-encoded calldata. |

---

### Rain API (issuing) — host responsibility

The SDK does not call the Rain issuing API. A host obtains, through its own Rain integration
(ideally server-side, keeping the program Api-Key off the device):

- the user's collateral contract — `GET /v1/issuing/users/{userId}/contracts` — whose
  `proxyAddress` / `controllerAddress` / token address feed a `RainWithdrawAddresses`;
- the admin withdrawal signature — `GET /v1/issuing/users/{userId}/signatures/withdrawals`
  (query: `chainId`, `token`, `amount` in base units, `adminAddress` from the contract's
  `adminAddresses`, `recipientAddress`, `isAmountNative`) — whose `signature.salt`,
  `signature.data` and `expiresAt` feed a `RainAdminSignature`. Until Rain has produced it the
  response's `status` is not `"ready"` and carries `retryAfter` seconds.

The demo app's `RainApiClient` is a minimal reference implementation.

#### tokenMetadata(chainId:address:) async throws -> TokenInfo?

Metadata (symbol, name, decimals) for a contract token known only by address — typically the
tokens listed in a collateral contract, which the Rain API returns without them. Resolution
order: built-in registry, host-registered tokens, then on-chain `decimals()` / `symbol()` /
`name()` reads over the configured RPC (cached once decimals resolve). Needs no wallet provider.

- **Returns:** `nil` only when decimals could not be established (RPC failure, unknown SPL mint)
  — never a guessed default, since wrong decimals would scale a withdrawal or approval amount by
  orders of magnitude. `symbol` / `name` inside a non-nil result may still be nil. Solana chains
  resolve from the registry and host-registered tokens only.
- **Throws:** `RainError.invalidConfig` for a chain with no RPC endpoint, a malformed `address`
  (same rules as `registerTokens`), or an on-chain `decimals()` outside `0...77`;
  `sdkNotInitialized` after `close()`. Same contract as Android.

---

## RainSdk.Builder

Assembles a `RainSdk`. Module dependencies decide which providers can be registered; the builder
never names a vendor SDK itself.

| Method | Description |
|--------|-------------|
| `rpcEndpoints(_ configs: [NetworkConfig])` | Sets the network configurations every provider shares. **Required.** |
| `rpcEndpoints(_ map: [Int: String])` | Same, from a `chainId → RPC URL` map (parity with Android). |
| `register(_ provider: any ProviderDescriptor)` | Registers a provider adapter (e.g. `PortalProvider`, `TurnkeyProvider`, `PrivyProvider`). Re-registering the same id replaces the prior one. |
| `registerTokens(_ tokens: [TokenInfo])` | Seeds the shared token store with extra token metadata. Validated at `build()` (address well-formed for its chain family, decimals in 0...77); a malformed entry fails the build with `invalidConfig`. |
| `authPullConfig(_ config: RainAuthPullConfig)` | Enables Auth Pull for the exact operator and token contracts in `config` (`.sandbox(operatorAddress:)` / `.production(operatorAddress:)` / `.custom(operatorAddress:tokenAddresses:)`). Without it, the approval, allowance, confirmation, and approval-fee methods fail closed. See [AUTH_PULL.md](AUTH_PULL.md). |
| `build() throws -> RainSdk` | Validates endpoints (fail-fast on a bad URL / chain id) and returns the SDK. Throws `RainError.invalidConfig` on invalid RPC endpoints, and on an invalid Auth Pull configuration: a malformed or zero operator or token address, an empty token map, a chain outside the Auth Pull set the config's kind names (`.custom` may use either environment's chains), or no RPC endpoint for any configured Auth Pull chain. Providers are optional: building with none yields a wallet-agnostic `RainSdk`. |

### Provider adapters

Each adapter is a `ProviderDescriptor` that owns its vendor SDK as a private dependency.

| Adapter | Module | Config | Notes |
|---------|--------|--------|-------|
| `PortalProvider(PortalConfig(sessionToken:sessionPolicy:onSessionTokenNeeded:onSessionExpired:), onPortalCreated:)` | `rain-portal-ios` | `sessionToken: String`, `sessionPolicy: PortalSessionPolicy`, `onSessionTokenNeeded: (() async throws -> String?)?`, `onSessionExpired: (() -> Void)?` | Portal MPC signer (EVM). Advertises `.export`, `.recovery`. The optional `onPortalCreated` hook hands the host the underlying `Portal` instance for Portal-specific APIs (backup / recover) and is re-fired after every session-token refresh. See [rain-portal-ios/README.md](../rain-portal-ios/README.md#session-expiry-and-retry) for session refresh and retry behavior. |
| `TurnkeyProvider(TurnkeyConfig(turnkey:walletAddress:sessionPolicy:onSessionExpired:))` | `rain-turnkey-ios` | `turnkey: TurnkeyContext`, `walletAddress: String?`, `sessionPolicy: TurnkeySessionPolicy`, `onSessionExpired: (() -> Void)?` | Turnkey P-256 signer (EVM + Solana). Advertises `.multiChain`, `.biometricGate`. See [TURNKEY_SUPPORT.md](TURNKEY_SUPPORT.md). |
| `PrivyProvider(PrivyConfig(privy:walletAddress:sessionPolicy:onSessionExpired:))` | `rain-privy-ios` | `privy: any Privy`, `walletAddress: String?`, `sessionPolicy: PrivySessionPolicy`, `onSessionExpired: (() -> Void)?` | Privy embedded-key signer (EVM + Solana). Advertises `.export`, `.recovery`, `.multiChain`. EVM custody routes through Privy's EIP-1193 embedded wallet; balance/fee reads use Rain's configured RPC. See [rain-privy-ios/README.md](../rain-privy-ios/README.md#session-expiry-and-retry). |

#### Platform differences (Portal)

Both adapters construct the vendor `Portal` with `autoApprove = true`,
`FeatureFlags(isMultiBackupEnabled = true)`, and the same `eip155:<chainId> → rpcUrl` RPC config.
Two differences are vendor-shaped and intentional:

- **Storage backends.** PortalSwift takes iCloud / keychain / password storage at construction, so
  the iOS adapter passes `ICloudStorage()`, `PortalKeychain()`, and `PasswordStorage()` there.
  portal-android registers backup storage at backup-call time instead, so the Android adapter
  passes none at construction.
- **`chainId`.** Android's `PortalConfig` has an optional `chainId` because portal-android's
  constructor **requires** a legacy `legacyEthChainId`, so its adapter must supply one. PortalSwift
  7.x takes no such parameter, so iOS's `PortalConfig` omits it. Vendor-imposed, not a parity gap.

**Bring your own provider:** implement the `WalletProvider` port and a `ProviderDescriptor`
descriptor (with your own `ProviderId`), then `register(...)` it. Core needs no change; the
wallet-agnostic building methods are available regardless of which provider you register.

---

## RainClient

Operations Rain exposes against a single, already-resolved wallet provider. Obtained from
`rain.provider(_:)` / `rain.first { … }`; bound to one provider for its lifetime, so it carries no
`initialize*` methods and never references a concrete vendor type.

Money APIs are `Decimal`-first: human-unit amounts and fees are `Decimal` everywhere (exact
base-10, no binary floating-point drift). Older `Double` variants survive only as deprecated shims.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `providerId` | `ProviderId` | Identifier of the provider backing this client (e.g. `.portal`). |
| `capabilities` | `Set<Capability>` | Optional behaviours the backing provider supports (see [Capabilities](#capabilities)). |
| `isInitialized` | `Bool` | Whether the SDK's chain configuration is set up. On iOS a client only exists once its provider resolved against a validated configuration, so this is always `true` for a live client (Android parity). |

---

### withdrawCollateral(chainId:addresses:amount:decimals:adminSignature:nonce:)

Full withdrawal flow: builds the calldata, obtains the admin EIP-712 signature via the backing
provider, submits on-chain, and returns the transaction hash.

- **Returns:** `String`: transaction hash (EVM) or transaction signature (Solana).
- **Throws:** `RainError` if construction, signing, or submission fails.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID (e.g. `43114`). |
| `addresses` | `RainWithdrawAddresses` | Proxy, controller, token, recipient addresses. |
| `amount` | `Decimal` | Amount in human-readable token units (e.g. `100`). |
| `decimals` | `Int` | Token decimals (e.g. 6 for USDC, 18 for most tokens). Load-bearing on every chain including Solana: it scales the amount and is **not** checked against the SPL mint, so pass the mint's real decimals. |
| `adminSignature` | `RainAdminSignature` | Rain's withdrawal authorization (host-fetched from the Rain API) — salt, signature, and expiry. |
| `nonce` | `BigUInt?` | Optional; if `nil`, SDK resolves from contract. Omit the argument entirely to get the same behaviour. |

---

### prepareWithdrawal(chainId:addresses:amount:decimals:adminSignature:nonce:)

Builds a withdrawal without broadcasting it. Takes the same parameters as `withdrawCollateral`.

This is **not** an offline build: it still prompts the wallet to sign EIP-712 (EVM) and reads the
collateral's admin set on chain. On Solana it additionally fetches a recent blockhash and simulates
the transaction.

- **Returns:** `RainPreparedWithdrawal` — `.evm(RainTransactionParameters)` carrying a complete,
  submittable transaction (`from` / `to` / `value` / `data`), or `.solana(UnsignedSolanaTransfer)`
  carrying the serialized unsigned transaction plus its `recentBlockhash`.
- **Throws:** `RainError` if construction or signing fails.
- **Async:** Yes

> A Solana blockhash is valid for roughly 150 slots (60–90 seconds). Submit promptly or re-prepare.

Use `evmParameters` / `solanaTransfer` to read the payload without writing a `switch`.

---

### getWalletAddress()

Returns the current wallet address from the backing provider.

- **Returns:** `String`: hex-encoded wallet address (e.g. `"0x..."`).
- **Throws:** `RainError` if the address cannot be retrieved.
- **Async:** Yes

---

### getWalletAddress(chainId:)

Returns the wallet address for a specific chain's family. For EVM chains this is the same hex
address as `getWalletAddress()`. A provider that also holds non-EVM accounts (advertising
`.multiChain`) returns the address matching `chainId`'s family, e.g. a base58 Solana address for
a Solana sentinel chain id (900 / 901 / 902). EVM-only providers return the hex address regardless.

- **Parameters:** `chainId: Int`
- **Returns:** `String`: the wallet address for that chain's family.
- **Throws:** `RainError` if the address cannot be retrieved.
- **Async:** Yes

---

### estimateGas(chainId:from:to:data:)

Estimates the gas fee required for a transaction.

- **Returns:** `Decimal`: estimated gas fee in the chain's native token (e.g. AVAX).
- **Throws:** `RainError` if estimation fails.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. |
| `from` | `String` | Sender wallet address. |
| `to` | `String` | Target contract address. |
| `data` | `String` | Hex-encoded transaction calldata (e.g. from `buildWithdrawTransactionData`). |

---

### estimateWithdrawalFee(chainId:addresses:amount:decimals:adminSignature:nonce:)

Estimates the total fee required to execute a collateral withdrawal transaction.

Internally builds + signs the EIP-712 payload, then runs `eth_estimateGas` against the withdrawal
controller; it does not broadcast.

> **This prompts the wallet to sign.** Building the estimate mints a fully signed withdrawal
> authorization — a user-visible prompt on providers that gate signing — for a fee quote.
> To quote without a second prompt, call `prepareWithdrawal` once and pass the result to
> `estimateWithdrawalFee(chainId:prepared:)` below.

- **Returns:** `Decimal`: estimated withdrawal fee in the chain's native token.
- **Throws:** `RainError` if estimation fails, or if `chainId` is a Solana chain — Solana fee
  estimation is not implemented.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. EVM only. |
| `addresses` | `RainWithdrawAddresses` | All addresses required for the withdrawal. |
| `amount` | `Decimal` | Human-readable amount to withdraw. |
| `decimals` | `Int` | Token decimals. |
| `adminSignature` | `RainAdminSignature` | Rain's withdrawal authorization (host-fetched from the Rain API). |
| `nonce` | `BigUInt?` | Optional; pin the estimate to the nonce the withdrawal will sign. If `nil`, resolved from the contract. |

---

### estimateWithdrawalFee(chainId:prepared:)

Estimates the total fee for a withdrawal already built by `prepareWithdrawal`, running
`eth_estimateGas` on the preparation's calldata. Builds and signs nothing new — no wallet prompt —
so the flow is: prepare once (one signature), quote the fee on the preparation, then submit.

- **Returns:** `Decimal`: estimated withdrawal fee in the chain's native token.
- **Throws:** `RainError` if estimation fails.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. EVM only. |
| `prepared` | `RainPreparedWithdrawal` | The withdrawal built by `prepareWithdrawal`. |

---

### sendNative(chainId:to:amount:)

Sends native tokens (e.g. ETH, AVAX, SOL) from the current wallet. Routed by `chainId`: Solana
sentinel chain ids (900 / 901 / 902) go through the provider's Solana path when it supports one.

- **Returns:** `RainTokenTransferResult`: carrying the transaction hash (EVM) or signature (Solana).
- **Throws:** `RainError` if the send fails or the provider does not support the chain family.
  A malformed EVM recipient fails as `invalidRecipient` before anything is broadcast.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID (EVM id or Solana sentinel). |
| `to` | `String` | Recipient address (hex on EVM, base58 on Solana). |
| `amount` | `Decimal` | Amount in human-readable form (e.g. `0.1` for 0.1 AVAX). |

---

### sendToken(chainId:contractAddress:to:amount:decimals:)

Sends ERC-20 (EVM) or SPL (Solana) tokens from the current wallet. Routed by `chainId`.

- **Returns:** `RainTokenTransferResult`: carrying the transaction hash.
- **Throws:** `RainError` if the send fails. A malformed EVM recipient fails as
  `invalidRecipient` before anything is broadcast.
- **On Solana:** supported by the providers that hold a Solana account (Turnkey and Privy; Portal
  throws). `decimals` does not scale the amount — the mint's on-chain value is authoritative, and
  this applies to `sendToken` only; see `withdrawCollateral`, where `decimals` **is** load-bearing —
  and a recipient with
  no token account for the mint gets an associated one created in the same transaction, paid for by
  the sender. The transfer is dry-run against the cluster before signing, so a doomed send fails as
  `tokenNotFound` / `tokenAccountNotFound` / `insufficientTokenBalance` / `invalidRecipient` /
  `transactionSimulationFailed` rather than silently failing on chain.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. |
| `contractAddress` | `String` | ERC-20 contract address (EVM) or SPL mint address (Solana). |
| `to` | `String` | Recipient wallet address. |
| `amount` | `Decimal` | Amount in human-readable form (e.g. `100` for 100 USDC). |
| `decimals` | `Int?` | Optional token decimals. When omitted / `nil`, the SDK resolves the token's `decimals()` from its registry or an on-chain read, so callers don't have to track it. |

---

### authPullChainIds

The chains this client will accept an Auth Pull approval on — the host's `RainAuthPullConfig`
narrowed to the chains that have an RPC endpoint, and the same set the approval guard enforces.
Empty until `RainSdk.Builder.authPullConfig(_:)` supplies the trusted targets. Also available on
`RainSdk` itself, for gating before a client is resolved.

Gate host UI on this rather than on `RainAuthPullChains.sandbox` / `.production`, which answer for an
environment and is the wider set. See [Auth Pull](AUTH_PULL.md#supported-chains-and-assets).

- **Type:** `Set<Int>`
- **Async:** No

---

### approveTokenAllowance(chainId:contractAddress:spender:amount:)

Approves `spender` to move up to `amount` of an ERC-20 token from the current wallet — the
wallet-side prerequisite for Rain's [Auth Pull](AUTH_PULL.md). Rain executes the pull itself; the
SDK only sets the allowance.

Auth Pull is disabled until `RainSdk.Builder.authPullConfig(_:)` supplies the trusted operator and
per-chain token targets. The SDK rejects any different chain, token, or spender before wallet access.

- **Returns:** `RainTokenApprovalResult`: carrying the transaction hash of the `approve` call.
- **Throws:** `RainError` if the approval fails. EVM only — a Solana `chainId` throws
  `internalError`, since SPL delegation is not an ERC-20 allowance. A `chainId` outside
  `authPullChainIds` throws `invalidConfig`.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target EVM network chain ID. Must be an Auth Pull chain for the configured environment. |
| `contractAddress` | `String` | ERC-20 token contract (USDC for Auth Pull today). |
| `spender` | `String` | Address being approved — Rain's operator. Source it from Rain; it differs between sandbox and production. |
| `amount` | `Decimal?` | Human-readable allowance (e.g. `250`). `nil` approves an unlimited (`uint256` max) allowance; `0` revokes. |

There is deliberately **no `decimals` parameter** on any Auth Pull method: the scale comes from
trusted registry metadata or a strict on-chain `decimals()` read, never from the caller. A token
whose decimals cannot be established throws `tokenNotFound` rather than being guessed at.

Convenience overload: `approveTokenAllowance(chainId:contractAddress:spender:)` (unlimited).

The new value is written straight over the old one. USDC accepts that; some ERC-20s (USDT and its
clones) revert unless an existing non-zero allowance is set to `0` first — see
[Auth Pull](AUTH_PULL.md#3-approve).

```swift
// Unlimited — what Rain recommends, so the user never has to re-approve.
let result = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia,
    contractAddress: usdc,
    spender: rainOperator
)

// Capped, then revoked.
_ = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia, contractAddress: usdc, spender: rainOperator, amount: 250)
_ = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia, contractAddress: usdc, spender: rainOperator, amount: 0)
```

---

### getTokenAllowance(chainId:contractAddress:spender:owner:)

Reads the ERC-20 allowance `spender` currently holds over `owner`'s balance. Call it before
approving (to skip a redundant transaction) and after (to confirm the approval was mined).

- **Returns:** `RainTokenAllowance`; see [RainTokenAllowance](#raintokenallowance).
- **Throws:** `RainError` if the read fails. EVM only.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target EVM network chain ID. |
| `contractAddress` | `String` | ERC-20 token contract. |
| `spender` | `String` | Address whose allowance is being read — Rain's operator. |
| `owner` | `String?` | Wallet whose balance is approved. `nil` reads this client's own wallet, which is the only case that touches the wallet provider at all. |

Convenience overload: `getTokenAllowance(chainId:contractAddress:spender:)`.

---

### estimateApprovalFee(chainId:contractAddress:spender:amount:)

Estimates the total fee (estimated gas × gas price) to submit the approval, in the chain's native
token. Nothing is broadcast and no signature is requested; the fee is priced against the exact
calldata `approveTokenAllowance` would send.

- **Returns:** `Decimal` — fee in the chain's native currency (e.g. ETH).
- **Throws:** `RainError`; `internalError` when the backing provider cannot estimate fees.
- **Async:** Yes

Parameters are identical to `approveTokenAllowance`. Convenience overload:
`estimateApprovalFee(chainId:contractAddress:spender:)`.

---

### confirmTokenAllowance(transactionHash:chainId:contractAddress:spender:amount:owner:)

Waits for an approval transaction to mine successfully, then reads back the resulting allowance. A
transaction hash alone means submitted, not ready: use this before treating the user as approved for
Auth Pull.

Polls `eth_getTransactionReceipt` once a second for up to 60 seconds, then reads the allowance
through the same path as `getTokenAllowance`, pinned to the block the receipt landed in. Transient
RPC failures on either read (a 429, a timeout, a node that has not reached the block yet) are
retried within the window rather than ending the confirmation.

- **Returns:** `RainTokenAllowance` — the allowance actually in place after the transaction mined.
- **Throws:** `RainError`. A reverted receipt throws `transactionSimulationFailed`. A window that
  expires with no receipt throws `transactionPending` with the transaction hash as `statusId` (not
  confirmed *yet* — re-read the allowance or confirm again rather than re-approving). A receipt that
  mined but whose allowance could not be read back within the window rethrows the last read failure
  (`networkError` when it was not already a `RainError`). `invalidConfig` for a malformed hash is
  final and is not retried. `internalError` is thrown only when the mined allowance contradicts
  the request: a revoke that left a spendable allowance, or an approval whose allowance is still zero.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `transactionHash` | `String` | Hash returned by `approveTokenAllowance`. |
| `chainId` | `Int` | Target EVM network chain ID. Must match the approval's chain. |
| `contractAddress` | `String` | ERC-20 token contract the approval was against. |
| `spender` | `String` | Address that was approved — Rain's operator. |
| `amount` | `Decimal?` | The allowance that was requested, so the result can be checked against it. `nil` means the unlimited approval; `0` means a revoke. |
| `owner` | `String?` | Wallet whose allowance to read. `nil` reads this client's own wallet. |

Convenience overloads: `confirmTokenAllowance(transactionHash:chainId:contractAddress:spender:)` and
`confirmTokenAllowance(transactionHash:chainId:contractAddress:spender:amount:)`.

**The returned allowance can be lower than `amount`.** Auth Pull spends this allowance, and USDC
decrements it on every `transferFrom` — including a `uint256` max one. An authorization that pulls
between the receipt and the read leaves less than was approved, and that is a success. Compare
`rawAmount` (or `covers(_:)`) against what you still need, not against what you asked for.

```swift
let result = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia, contractAddress: usdc, spender: rainOperator)
let allowance = try await client.confirmTokenAllowance(
    transactionHash: result.transactionHash,
    chainId: RainChain.baseSepolia,
    contractAddress: usdc,
    spender: rainOperator
)
```

---

### RainTokenAllowance

| Member | Type | Description |
|--------|------|-------------|
| `rawAmount` | `BigUInt` | Exact allowance in the token's smallest unit. Never lossy. |
| `decimals` | `Int` | The token's decimals (e.g. 6 for USDC). |
| `chainId` / `tokenAddress` / `owner` / `spender` | | What was read, so a merged list stays self-describing. |
| `isUnlimited` | `Bool` | `rawAmount == uint256` max. Exact: some tokens decrement even a max allowance, so `false` does not mean "must re-approve" — compare `rawAmount` against what you need. |
| `isZero` | `Bool` | Nothing approved — the state after a revoke. |
| `decimalAmount` | `Decimal` | `rawAmount / 10^decimals`, for display. `Decimal` holds 38 significant digits, so an unlimited allowance (72 digits at USDC's 6) is rounded here — check `isUnlimited` before rendering. |
| `formatted` | `String` | Display string with trailing zeros trimmed; same rounding caveat. |
| `covers(_:)` | `(Decimal) -> Bool` | Whether a human-readable amount is still covered, compared in exact base units. An amount that cannot be represented at all (negative, or finer than the token's scale) is `false` too. |

---

### Balance value type

All balance methods return rich `Balance` values rather than lossy `Double`s.

| Field | Type | Description |
|-------|------|-------------|
| `token` | `Token` | `.native` or `.contract(address:)`. |
| `chainId` | `Int` | Chain ID the balance was read on. |
| `rawAmount` | `BigUInt` | Exact balance in the token's smallest unit (never lossy). |
| `decimals` | `Int` | Token decimal places (e.g. 6 for USDC, 18 for ETH). |
| `symbol` | `String?` | Token symbol, when known. |
| `name` | `String?` | Human-readable name, when known. |
| `decimalAmount` | `Decimal` | Derived: `rawAmount / 10^decimals`. |
| `formatted` | `String` | Derived display string (e.g. `"1.5"`). |

---

### getBalance(chainId:token:)

Fetches a single balance (native or a contract token) for the current wallet.

- **Returns:** `Balance`: exact `rawAmount` plus resolved decimals / symbol / name.
- **Throws:** `RainError` if the request fails.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID (e.g. `43114` for Avalanche Mainnet). |
| `token` | `Token` | `.native`, or `.contract(address:)` (address comparison is case-insensitive). |

---

### getTokenBalances(chainId:)

Fetches all non-zero balances for the current wallet on the given network. The native balance is
always included; zero-balance contract tokens are omitted. Supersedes the deprecated
`getBalances(chainId:)`, which returned a lossy `[String: Double]`.

- **Returns:** `[Balance]`: one per non-zero token plus the native balance.
- **Throws:** `RainError` if the request fails.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. |

---

### getAllBalances()

Fetches balances across every configured chain in parallel, flattened into a single list. Each
`Balance` carries its own `chainId`. Per-chain failures are tolerated: a chain that errors out
contributes no entries rather than failing the whole call.

- **Returns:** `[Balance]`: a flat list spanning all healthy configured chains.
- **Throws:** `RainError` if the request fails.
- **Async:** Yes

---

### generateAddressQRCode(address:dimension:backgroundColor:foregroundColor:)

Generates a square QR code image (PNG) encoding `address` — or the wallet's own address when
`address` is `nil`. Use it for any address the host shows: a chain-specific wallet address (the
Solana account rather than the EVM one) or a Rain collateral deposit address.

A convenience overload, `generateAddressQRCode(address:)`, applies the defaults below.

- **Returns:** `Data`: PNG image bytes.
- **Throws:** `RainError` if the wallet address is needed but unavailable, or QR generation fails.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `address` | `String?` | Address to encode; `nil` uses the provider's wallet address. |
| `dimension` | `Int` | Output width/height in pixels (`256` via the convenience overload). |
| `backgroundColor` | `CGColor?` | Optional; default white. |
| `foregroundColor` | `CGColor?` | Optional; default black. |

---

### getTransactions(chainId:limit:offset:order:)

Fetches transaction history for the current wallet on the given network.

- **Returns:** `[RainTransaction]`: transaction records. `value` is a `Decimal?` in human-readable units — `nil` when decimals could not be resolved, with `rawValue` still populated.
- **Throws:** `RainError` if transaction history cannot be retrieved.
- **On Solana:** rows cover native SOL (`category: "external"`) and SPL tokens
  (`category: .token`, with the mint in `tokenAddress` and the raw amount in `rawValue`); token accounts are
  reported as the wallets behind them where they can be resolved. What is listed depends on the
  provider's source: Turnkey reads its own activity log, so only sends made through the SDK appear,
  with the Turnkey status id as the hash.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `chainId` | `Int` | Target network chain ID. |
| `limit` | `Int?` | Optional max number of transactions to return. |
| `offset` | `Int?` | Optional pagination offset. |
| `order` | `RainTransactionOrder?` | Optional sort order: `.ASC` or `.DESC`. |

A convenience overload defaults `limit`, `offset`, and `order` to `nil`, so `getTransactions(chainId:)`
is a valid call.

---

### registerTokens(_ tokens: [TokenInfo]) async throws

Registers token metadata so balance and transfer calls resolve symbol / decimals without an
on-chain read. The store is shared with the owning `RainSdk`, so every resolved client sees the
registration; entries are stored before the call returns. The whole list is validated first (see
`RainSdk.registerTokens`) and one bad entry registers nothing. Also available on `RainSdk` and on
the builder.

- **Throws:** `RainError.invalidConfig` on a malformed entry.
- **Async:** Yes

| Parameter | Type | Description |
|-----------|------|-------------|
| `tokens` | `[TokenInfo]` | Token metadata to register. Re-registering a host-added address replaces its entry; built-in registry tokens are trusted and cannot be overridden. |

---

### reset()

Clears client-held state. On iOS a resolved client is immutable (configuration and the backing
provider are fixed at resolution), so this is an idempotent no-op that exists for parity with
Android's `RainClient.reset()`. Prefer `RainSdk.reset()`, which evicts resolved clients so they
re-resolve on next access.

- **Async:** No

---

## Removed in v5

The 1.x compatibility shims (`generateWalletAddressQRCode`, `sendERC20Token`, `sendNativeToken`,
the `Double`-based `sendToken`, `getNativeBalance`, `getERC20Balance(s)`, `getBalances`,
`RainSdk.composeTransactionParameters`) are gone. Use the precise current API:
`generateAddressQRCode(address: nil, …)`, `sendToken` / `sendNative` (returning
`RainTokenTransferResult`), `getBalance` / `getTokenBalances` (returning `Balance` with exact
`rawAmount`), and `buildTransactionParameters`. Same surface as the Android SDK.

---

## Capabilities

A provider advertises optional behaviours via `Capability`, so hosts can resolve by feature
(`rain.first { $0.capabilities.contains(.export) }`) and degrade gracefully instead of assuming a
capability every provider has.

| Capability | Meaning |
|------------|---------|
| `.export` | The wallet's key material can be exported / backed up. |
| `.recovery` | The wallet supports a recovery ceremony. |
| `.multiChain` | The provider holds accounts across multiple chain families (e.g. EVM + Solana). |
| `.biometricGate` | Every signature is gated behind a device biometric / passkey prompt. No bundled provider advertises it (Turnkey signs with a `.none`-policy enclave key); reserved for third-party adapters. |

Bundled providers: **Portal** → `.export`, `.recovery`. **Turnkey** and **Rain wallet** →
`.export`, `.multiChain`, plus `.gasSponsorship` when `sponsorGas` is on. **Privy** → `.export`,
`.recovery`, `.multiChain`.

---

## Types

| Type | Description |
|------|-------------|
| **`ProviderId`** | Struct wrapping a provider id string. Well-known constants: `.portal`, `.turnkey`, `.privy`. Host apps can ship a custom id. |
| **`Capability`** | Enum: `.export`, `.recovery`, `.multiChain`, `.biometricGate`. |
| **`ProviderDescriptor`** | Registrable provider descriptor: `id`, `capabilities`, and an async `create(context:)` that materializes the `WalletProvider`. Implemented by `PortalProvider`, `TurnkeyProvider`, `PrivyProvider`, and host-supplied providers. |
| **`WalletProvider`** | The port each adapter implements. Public so hosts can ship their own wallet stack. |
| **`NetworkConfig`** | `chainId`, `rpcUrl`, optional `networkName`. Also constructible from an `eip155:<chainId>` string. |
| **`RainWithdrawAddresses`** | `proxyAddress`, `controllerAddress`, `tokenAddress`, `recipientAddress`. Has `validated()` for checksumming. |
| **`RainEIP712Message`** | `message`, `salt`, `saltHex`. Returned by `buildEIP712Message`. |
| **`RainAdminSignature`** | `salt` (String), `signature` (hex String), `expiresAt` (String, ISO-8601 or Unix timestamp). Built by the host from the Rain API's withdrawal-signature response. |
| **`RainTokenTransferResult`** | `transactionHash` (String): on-chain hash (EVM) or signature (Solana). Returned by `sendNative` and `sendToken`. |
| **`RainTokenApprovalResult`** | `transactionHash` (String): hash of the ERC-20 `approve` call. Returned by `approveTokenAllowance`. |
| **`RainTokenAllowance`** | Exact allowance value type; see [RainTokenAllowance](#raintokenallowance). |
| **`RainAuthPullConfig`** | Trusted Auth Pull targets for one environment: `operatorAddress` plus a `chainId → token contract` map. Built via `.sandbox(operatorAddress:)`, `.production(operatorAddress:)`, or `.custom(operatorAddress:tokenAddresses:)`; passed to `RainSdk.Builder.authPullConfig(_:)`. |
| **`RainAuthPullChains`** | The Auth Pull chain sets by environment: `.sandbox` (Base Sepolia, Arbitrum Sepolia), `.production` (Base, Arbitrum). |
| **`RainChain`** | Pinned chain IDs: `.baseMainnet` (8453), `.baseSepolia` (84532), `.arbitrumMainnet` (42161), `.arbitrumSepolia` (421614), `.avalancheMainnet` / `.avalancheTestnet`, and the Solana sentinels. |
| **`RainTransactionParameters`** | `from`, `to`, `value` (hex wei), `data` (hex calldata). Wallet-agnostic parameter bag returned by `buildTransactionParameters`. |
| **`Token`** | `.native` or `.contract(address:)`; contract equality is case-insensitive. |
| **`TokenInfo`** | `chainId`, `address`, `symbol?`, `decimals`, `name?`. Used to seed the token store. |
| **`Balance`** | Exact balance value type; see [Balance value type](#balance-value-type). |
| **`RainTransaction`** | Transaction record: `hash`, `uniqueId`, `blockNumber`, `timestamp`, `from`, `to`, `value`, `asset`, `tokenAddress`, `rawValue`, `decimals`, `category`, `chainId`, `metadata`. Returned by `getTransactions`. Identical in shape to the Android type. |
| **`RainTransactionOrder`** | Enum: `.ASC`, `.DESC`. Used in `getTransactions(..., order:)`. |
| **`RainTransactionCategory`** | Extensible constant: `.external`, `.token`, `.erc20`, `.erc721`, `.erc1155`, `.contractInternal`. |

---

## Errors

All async methods can throw `RainError`. Each error carries a stable `code` string (`"RAIN_xxx"`)
for programmatic handling — the same codes as the Android SDK.

| Code | Case | Meaning |
|------|------|--------|
| `RAIN_101` | `sdkNotInitialized` | Operation called before the SDK's configuration was set up. |
| `RAIN_102` | `invalidConfig(details:)` / `providerNotRegistered(details:)` | Invalid configuration or parameter (bad RPC URL / chain ID, malformed address or expiry); no provider registered for the requested id; or no provider matched a capability. |
| `RAIN_103` | `invalidRpcUrl(_:)` | RPC URL could not be parsed as a valid URL. |
| `RAIN_104` | `chainNotSupported(chainId:details:)` | The active wallet provider cannot broadcast on this chain, so a send (transfer, withdrawal, approval) was refused before any signing or network work. Reads — balances, history, fee estimates — are not gated. E.g. Turnkey's managed broadcast does not cover Avalanche. |
| `RAIN_201` | `tokenExpired` | Provider session token expired or invalid. |
| `RAIN_202` | `unauthorized(details:)` | The backend rejected the caller's credentials or permissions; `details` names which backend and why. On a Rain wallet code login: the wallet auth token was rejected even after one renewal from your `authTokenProvider`, or the tenant cannot use embedded wallets. |
| `RAIN_203` | `invalidLoginCode` | The one-time login code was rejected (wrong, expired, or already used) — ask the user to retype it or request a new one. Distinct from `RAIN_201`, which means an established session died. |
| `RAIN_301` | `networkError(underlying:)` | Network/connectivity failure. |
| `RAIN_302` | `transactionPending(statusId:)` | A send was accepted but its hash is not known yet; resume polling with `statusId`, do not resend. On a Turnkey or Rain wallet send, EVM or Solana, whose activity the backend accepted without a readable status id yet, `statusId` is the backend's activity id — no call takes it, but it matches the history row for the send. |
| `RAIN_305` | `transactionOutcomeUnknown(details:)` | The send was handed to the wallet provider and the SDK then lost track of it — a server error, a transport failure or an unreadable answer after the provider may already have accepted it — so there is no identifier to resume from. Not a settled failure: the transaction may still land, and resending risks a duplicate transfer. Read history or the balance before sending again. Raised by the Turnkey provider and the Rain wallet in the cases under [After a send is accepted](TURNKEY_SUPPORT.md#after-a-send-is-accepted). `RAIN_501` from a Turnkey or Rain wallet send means the send settled as failed or was refused, and nothing moved. (303 and 304 are retired; the sequence resumes at 305, as on Android.) |
| `RAIN_401` | `userRejected` | User cancelled the signing request in the wallet. |
| `RAIN_402` | `insufficientFunds(required:available:)` | Balance too low for the requested amount or gas. |
| `RAIN_403` | `transactionSimulationFailed(underlying:)` | Preflight `eth_call` simulation failed (e.g. contract revert, insufficient funds). |
| `RAIN_404` | `walletUnavailable(details:)` | The backing provider returned no usable wallet address for this chain family. |
| `RAIN_405` | `withdrawalRevertedByNetwork(details:)` | The collateral contract rejected the withdrawal (e.g. already-used or expired admin signature, duplicate amount inside the cooldown); `details` carries the decoded reason when available. |
| `RAIN_406` | `invalidAmount(amount:reason:)` | The amount is invalid for the token (more decimal places than the token supports, or unrepresentable). |
| `RAIN_407` | `walletNotAuthorized(walletAddress:proxyAddress:)` | The signing wallet is not an admin of the collateral contract. |
| `RAIN_501` | `providerError(underlying:)` | Portal, Turnkey, Privy, or other provider error. |
| `RAIN_502` | `internalError(details:)` | EIP-712 encoding, ABI encoding, or internal processing error. |

### Error handling example

```swift
do {
    let client = try await rain.provider(.portal)
    let txHash = try await client.withdrawCollateral(...)
} catch let error as RainError {
    switch error {
    case .providerNotRegistered: /* Unknown provider id */ break
    case .insufficientFunds: /* Not enough balance */ break
    case .networkError(let underlying): /* Network issue */ break
    default: print("\(error.code): \(error.localizedDescription)")
    }
}
```
