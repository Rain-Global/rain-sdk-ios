# Rain SDK iOS

[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)](#installation)
[![CocoaPods](https://img.shields.io/badge/CocoaPods-not--supported-lightgrey)](#installation)
[![Carthage](https://img.shields.io/badge/Carthage-not--supported-lightgrey)](#installation)

iOS SDK with first-class [Portal](https://portalhq.io), [Turnkey](https://www.turnkey.com), and
[Privy](https://privy.io) wallet support: build EIP-712 messages, compose withdrawal transactions,
sign and submit through a registered wallet provider, read balances and history, and estimate fees.
Works on EVM chains and Solana.

The SDK is **modular** (ports & adapters): a vendor-free **`RainCore`** plus one adapter module per
wallet provider. Link only the providers you use — an unselected provider's vendor SDK never enters
your dependency graph. Each adapter re-exports `RainCore`, so one import per provider is enough.

| Module        | Contains                                                                 |
|---------------|--------------------------------------------------------------------------|
| `RainCore`    | The `WalletProvider` port, capability model, provider registry (`RainSdk`), and all Rain domain logic. No wallet vendor SDKs. |
| `RainTurnkey` | The Turnkey adapter (`TurnkeyProvider`); depends on `RainCore` + Turnkey's Swift SDK. |
| `RainPortal`  | The Portal MPC adapter (`PortalProvider`); depends on `RainCore` + `PortalSwift`. |
| `RainWallet`  | The Rain-branded wallet (`RainProvider`); the backend identity is embedded, and the SDK owns authentication (email login codes), wallet provisioning, and sessions. |
| `RainPrivy`   | The Privy embedded-key adapter (`PrivyProvider`); depends on `RainCore` + the Privy iOS SDK (`Privy`). Custody (sign/send) routes through Privy's EIP-1193 embedded wallet; balance/fee reads use Rain's configured RPC. |

The 1.x `RainSDK` umbrella module has been removed — link the provider product you use.

## Features

- **Portal wallet integration** — Register a `PortalProvider` with a Portal session token; resolve a `RainClient` and use the connected MPC wallet for signing and sending transactions. See [rain-portal-ios/README.md](rain-portal-ios/README.md#session-expiry-and-retry) for session refresh and retry behavior.
- **Turnkey wallet integration** — bring your own authenticated `TurnkeyContext` (auth proxy / passkeys / OAuth / OTP driven by the host); Rain handles sessions, signing, and multi-chain resolution. Ships in its own `rain-turnkey-ios` module. SDK-owned email-OTP auth is available through the Rain-branded `RainWallet` provider.
- **Rain wallet** — Register a `RainProvider` (the backend identity is embedded; you supply the Rain environment and a closure that fetches wallet auth tokens from your backend); the SDK runs login-code auth over email or SMS (`sendLoginCode(to:)` / `confirmLoginCode`) and passkeys (`loginWithPasskey` / `signUpWithPasskey` / `addPasskey`), provisions one wallet with EVM + Solana accounts on first login, manages the session, and supports on-device key export (`exportRecoveryPhrase` / `exportPrivateKey`). See [rain-wallet-ios/README.md](rain-wallet-ios/README.md).
- **Privy wallet integration** — Register a `PrivyProvider` with an authenticated `Privy` singleton (auth + embedded-wallet provisioning handled outside Rain by the Privy iOS SDK); custody routes through Privy's EIP-1193 embedded wallet.
- **Pluggable providers** — Bring your own `WalletProvider` behind a `ProviderDescriptor` and register it; resolve providers by id or by `Capability`.
- **Wallet-agnostic utilities** — EIP-712 message + withdraw calldata building are available straight off `RainSdk` with no provider resolved — use them with your own wallet or backend.
- **EIP-712 message building** — Build typed data for admin signature required by the collateral contract.
- **Withdrawal transaction building** — Build ABI-encoded withdraw calldata for submission.
- **Solana support** — native SOL and SPL transfers, balances, history, and collateral withdrawal, on the same `RainClient` methods as EVM. See [Solana](#10-solana).
- **Full withdrawal flow** — builds the transaction, signs via the backing provider, and submits; returns the transaction hash.
- **Fee estimation** — returns the estimated gas cost in the chain’s native token (e.g. ETH).
- **Wallet information** — get the wallet address (per chain family) and generate a QR code image (PNG) for it or for any other address.
- **Balances** — get native, ERC-20, and SPL token balances for the current wallet.
- **Transaction history** — get transactions for the current wallet with optional pagination and sort order (`WalletTransaction`, `WalletTransactionOrder`).
- **Send tokens** — send native, ERC-20, or SPL tokens from the current wallet.
- **Auth Pull approvals** — approve Rain's operator to spend the user's USDC, read the allowance back, confirm it on chain, and estimate the approval fee. See [Auth Pull](docs/AUTH_PULL.md).
- **Exact money handling** — public money APIs are `Decimal`; base-unit conversion is exact and rejects an amount finer than the token's scale rather than truncating it.

## Installation

### Swift Package Manager

Add the package in Xcode (**File → Add Package Dependencies**) with:

```
https://github.com/SignifyHQ/rain-sdk-ios
```

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SignifyHQ/rain-sdk-ios", from: "5.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "rain-portal-ios", package: "rain-sdk-ios")
    ])
]
```

The package vends one product per wallet provider, so you link **only the providers you use** — an
unselected provider's vendor SDK is never linked into your app:

| Product | Link it for | Import |
|---|---|---|
| `rain-wallet-ios` | The Rain wallet | `import RainWallet` |
| `rain-turnkey-ios` | Turnkey wallets | `import RainTurnkey` |
| `rain-portal-ios` | Portal MPC wallets | `import RainPortal` |
| `rain-privy-ios` | Privy embedded wallets | `import RainPrivy` |
| `rain-core-ios` | Transaction building with your own wallet, or a custom `WalletProvider` | `import RainCore` |

`RainCore` comes transitively with every adapter — you never list it twice — and each adapter
re-exports it, so the adapter import alone surfaces the full SDK (`RainSdk`, `RainClient`, models,
errors).

```swift
// Rain wallet app.
.product(name: "rain-wallet-ios", package: "rain-sdk-ios")
// Turnkey-only app.
// .product(name: "rain-turnkey-ios", package: "rain-sdk-ios")
// Portal-only app.
// .product(name: "rain-portal-ios", package: "rain-sdk-ios")
// Privy-only app.
// .product(name: "rain-privy-ios", package: "rain-sdk-ios")
// Wallet-agnostic transaction building only.
// .product(name: "rain-core-ios", package: "rain-sdk-ios")
```

The 1.x **`RainSDK`** umbrella product has been removed. If you were importing `RainSDK`, link the
provider product(s) you actually use and import those modules instead.

## Migrating from earlier versions

**From v2–v4:** the `RainSDK` umbrella module was removed, and the Turnkey adapter moved from
`RainCore` to its own `rain-turnkey-ios` product. `import RainSDK` no longer resolves — link the
provider product(s) you use and import those modules. Turnkey apps add `rain-turnkey-ios` and
`import RainTurnkey`; the Turnkey API itself (`TurnkeyProvider`, `TurnkeyConfig`, `.turnkey`,
session surface) is unchanged.

**From 1.x:** the 1.x entry point was replaced — there are no shims for it:

| 1.x | v2 |
|---|---|
| `RainSDKManager()` | `RainSdk.builder().rpcEndpoints(…).register(…).build()` |
| `initializePortal(portalSessionToken:networkConfigs:)` | `.register(PortalProvider(PortalConfig(sessionToken:)))` + `rain.provider(.portal)` |
| `initializeTurnkey(turnkey:networkConfigs:walletAddress:)` | `.register(TurnkeyProvider(TurnkeyConfig(turnkey:)))` + `rain.provider(.turnkey)` |
| `initialize(networkConfigs:)` (wallet-agnostic) | `RainSdk.builder().rpcEndpoints(…).build()` — building methods live on `RainSdk` |
| `manager.portal` accessor | `PortalProvider(_, onPortalCreated:)` hook |
| `manager.turnkey` accessor | none — the host already owns its `TurnkeyContext` |
| `setWalletProvider` | none: a resolved `RainClient` is immutable; register multiple providers and resolve each instead |
| `reset()` | `RainSdk.reset()`, which tears down resolved clients (they re-resolve on next access) |

Business methods (`sendToken`, `withdrawCollateral`, balances, …) kept their names on
`RainClient`; renamed/retyped 1.x variants remain as deprecated shims (see `Deprecated.swift`
in `RainCore` and `RainPortal`).

## Requirements

- iOS 17.0+
- Swift 6.1+
- Xcode 16.3+

## Usage

### 1. Portal (full wallet flow)

Register a `PortalProvider` and resolve a `RainClient`.

```swift
import RainPortal   // re-exports RainCore

let rain = try RainSdk.builder()
    .rpcEndpoints([
        1: "https://mainnet.infura.io/v3/YOUR_KEY",
        137: "https://polygon-rpc.com",
    ])
    .register(PortalProvider(PortalConfig(sessionToken: "<your-portal-session-token>")))
    .build()

// Resolve the Portal-backed client (suspends — materializes the wallet on first access).
let client = try await rain.provider(.portal)
```

### 2. Turnkey (bring your own auth)

Like Portal and Privy, authentication lives outside the SDK: drive Turnkey's Swift SDK yourself
(auth proxy / passkeys / OAuth / OTP), then hand the authenticated `TurnkeyContext` to Rain:

```swift
import RainTurnkey   // re-exports RainCore

let rain = try RainSdk.builder()
    .rpcEndpoints([43114: "https://avalanche-c-chain-rpc.publicnode.com"])
    .register(
        TurnkeyProvider(
            TurnkeyConfig(
                turnkey: turnkeyContext,   // your authenticated context
                walletAddress: nil         // omit to use the first Ethereum account
            )
        )
    )
    .build()

let client = try await rain.provider(.turnkey)
```

See [rain-turnkey-ios/README.md](rain-turnkey-ios/README.md) for details. SDK-owned email-OTP
authentication is available through the Rain-branded `RainWallet` provider instead.

### 3. Bring your own provider, or resolve by capability

The registry is designed for the multi-provider case; a single-provider app is just the trivial
`N = 1` instance of it. Register your own `WalletProvider` behind a `ProviderDescriptor`,
then resolve by id or by capability:

```swift
// …or resolve the first registered provider with a given capability
let exporter = try await rain.first { $0.capabilities.contains(.export) }
```

### 4. Wallet-agnostic building (no provider resolved)

EIP-712 message and withdraw calldata building are available directly off `RainSdk`:

```swift
let (message, salt) = try await rain.buildEIP712Message(
    chainId: 1, walletAddress: "0x…", assetAddresses: addresses,
    amount: 100, decimals: 6, nonce: nil
)
```

### 5. Get wallet address

```swift
let address = try await client.getWalletAddress()

// Per-chain family — returns the Solana account for Solana sentinel chains, the EVM address otherwise:
let solAddress = try await client.getWalletAddress(chainId: solanaChainId)
```

### 6. Read balances

Balances are returned as rich `Balance` values that carry the exact base-unit `rawAmount`
(a `BigUInt`, never lossy) alongside resolved `decimals`/`symbol`/`name` and convenience
`decimalAmount` / `formatted` accessors. A `Token` is either `.native` or `.contract(address:)`.

```swift
// A single balance (native or a specific token):
let eth = try await client.getBalance(chainId: 1, token: .native)
let usdc = try await client.getBalance(
    chainId: 1,
    token: .contract(address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
)
print(usdc.formatted)       // e.g. "1.5"
print(usdc.rawAmount)       // exact base units, e.g. 1500000

// Every non-zero balance on a chain (native is always included):
let balances = try await client.getTokenBalances(chainId: 1)

// Every balance across all configured chains, flattened (each Balance carries its chainId):
let all = try await client.getAllBalances()
```

Token metadata for well-known tokens is built in. To resolve a token the SDK doesn't know
about without an on-chain `decimals()` / `symbol()` lookup, register it up front on the builder:

```swift
RainSdk.builder()
    .registerTokens([
        TokenInfo(chainId: 1, address: "0x…", symbol: "FOO", decimals: 18, name: "Foo Token")
    ])
    // …
```

Unregistered contract tokens are still resolved automatically by reading `decimals()` /
`symbol()` on-chain once, then cached. Built-in tokens are trusted: a registration for an address
the SDK already ships is ignored, so a wrong `decimals` cannot rescale a known token's balances or
approvals.

### 7. Send tokens

Both return a `RainTokenTransferResult` carrying the `transactionHash`.

```swift
// Native token (e.g. ETH, AVAX):
let native = try await client.sendNative(chainId: 1, to: "0x…", amount: 0.1)
print(native.transactionHash)

// ERC-20 (EVM) / SPL (Solana) — omit `decimals` to let the SDK resolve them:
let erc20 = try await client.sendToken(
    chainId: 1, contractAddress: "0x…", to: "0x…", amount: 100
)
```

### 8. Rain API: collateral contracts & admin signature (host responsibility)

The SDK does **not** call the Rain issuing API. The two things a withdrawal needs from Rain — the
user's collateral contract (addresses) and Rain's admin withdrawal signature — come from your own
integration, ideally server-to-server so the program **Api-Key** never ships in the app:

- `GET /v1/issuing/users/{userId}/contracts` → `proxyAddress`, `controllerAddress`,
  `adminAddresses`, `tokens[]` → build a `RainWithdrawAddresses`.
- `GET /v1/issuing/users/{userId}/signatures/withdrawals?chainId=&token=&amount=&adminAddress=&recipientAddress=&isAmountNative=`
  → `signature.salt` / `signature.data` / `expiresAt` → build a `RainAdminSignature`. While Rain
  prepares the signature the response carries `status != "ready"` and a `retryAfter`; poll.

Token name/symbol/decimals are not in the contracts response; resolve them from the address with
`try await rain.tokenMetadata(chainId:address:)` (registry → registered tokens → on-chain reads;
`nil` when decimals cannot be established, never a guess; throws `invalidConfig` for a malformed
address, a chain without an RPC endpoint, or on-chain decimals outside 0...77).

```swift
let addresses = RainWithdrawAddresses(
    proxyAddress: contract.proxyAddress,
    controllerAddress: contract.controllerAddress,
    tokenAddress: contract.tokens[0].address,
    recipientAddress: "0x…"
)
let adminSignature = RainAdminSignature(salt: sig.salt, signature: sig.data, expiresAt: sig.expiresAt)
// both feed withdrawCollateral below
```

The demo app ships a minimal reference client
(`Example/RainSDKDemo/RainSDKDemo/Core/Services/RainApiClient.swift`).

### 9. Withdraw collateral

Signs the admin EIP-712 message via the backing provider, submits, and returns the tx hash.

```swift
let addresses = WithdrawAssetAddresses(
    contractAddress: "0x…",
    proxyAddress: "0x…",
    recipientAddress: "0x…",
    tokenAddress: "0x…"
)

let txHash = try await client.withdrawCollateral(
    chainId: 1,
    assetAddresses: addresses,
    amount: 100,
    decimals: 6,
    salt: "…",
    signature: "…",
    expiresAt: "2024-12-31T23:59:59Z",
    nonce: nil // omit to read the latest nonce on-chain
)
```

For manual submission (build the calldata yourself, no provider resolved), use the wallet-agnostic
`rain.buildWithdrawTransactionData(...)` from section 4.

### 10. Solana

Solana uses the same `RainClient` methods as EVM — the SDK routes on the chain ID. `RainChain`
exposes the sentinel IDs (`solanaMainnet` 900, `solanaDevnet` 901, `solanaTestnet` 902); these are
Rain's routing IDs, not Solana chain IDs. Register a Solana RPC URL against them like any other
chain. `RainChain.isSolana(_:)` and `solanaCaip2(for:)` are available if the host needs to branch.

```swift
let client = try await rain.provider(.turnkey)   // or .privy; Portal has no Solana account
let chainId = RainChain.solanaDevnet

try await client.getWalletAddress(chainId: chainId)        // the Solana account, not the EVM address
try await client.getBalance(chainId: chainId, token: .native)   // SOL
try await client.getTokenBalances(chainId: chainId)             // SPL holdings
try await client.sendNative(chainId: chainId, to: recipientBase58, amount: 0.01)
try await client.sendToken(
    chainId: chainId,
    contractAddress: mintAddress,
    to: recipientBase58,
    amount: 1.5
)
```

`withdrawCollateral` works unchanged, with `proxyAddress` as the collateral account and
`tokenAddress` as the SPL mint (`contractAddress` is unused — there is no coordinator contract to
call). Under the hood the withdrawal is authorized by Rain's coordinator signing a message off chain
rather than by EVM calldata, so the SDK composes and simulates a collateral-program transaction and
the provider signs it. See [TURNKEY_SUPPORT.md](docs/TURNKEY_SUPPORT.md#solana-notes) for details.

On `sendToken`, an SPL mint's decimals are read from the chain, so the `decimals` argument does not
scale the amount. `withdrawCollateral` and `prepareWithdrawal` are the opposite: there `decimals`
**does** scale the amount and is not checked against the mint, so pass the mint's real decimals.
Mints carry no on-chain symbol — `registerTokens(_:)` names the ones you want displayed.
### 11. Estimate withdrawal fee

Returns the estimated total fee in the chain's native token (e.g. ETH).

```swift
let fee = try await client.estimateWithdrawalFee(
    chainId: 1,
    addresses: addresses,
    amount: 100,
    decimals: 6,
    salt: "…",
    signature: "…",
    expiresAt: "2024-12-31T23:59:59Z"
)
print("Estimated fee: \(fee)")
```

### 12. Transaction history

```swift
let txs = try await client.getTransactions(
    chainId: 1,
    limit: 20,
    offset: 0,
    order: .DESC
)
for tx in txs {
    print("\(tx.hash) — \(tx.from) → \(tx.to ?? "—")")
}
```

### 13. Auth Pull: approve the Rain operator

Auth Pull draws a card authorization's amount straight from the user's wallet into their Rain
collateral contract. The wallet-side prerequisite is an ERC-20 allowance for Rain's operator — that
part is the SDK's; the pull itself is Rain's.

```swift
let rain = try RainSdk.builder()
    .rpcEndpoints(rpcEndpoints)
    .authPullConfig(.sandbox(operatorAddress: rainOperatorAddress))
    .register(provider)
    .build()

let client = try await rain.provider(provider.id)

// 1. What can the operator move today?
let allowance = try await client.getTokenAllowance(
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: rainOperatorAddress   // per environment; read it from Rain
)
guard !allowance.covers(expectedSpend) else { return }

// 2. What will the approval cost?
let fee = try await client.estimateApprovalFee(
    chainId: RainChain.baseSepolia, contractAddress: usdcAddress, spender: rainOperatorAddress)

// 3. Approve. Omitting `amount` approves an unlimited allowance, so the user never re-approves;
//    pass a Decimal to cap it, or 0 to revoke.
let result = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia, contractAddress: usdcAddress, spender: rainOperatorAddress)
print(result.transactionHash)

// 4. A hash means submitted, not ready. Wait for a successful receipt, then read the allowance that
//    actually landed — it can be lower than approved if an authorization already pulled against it.
let confirmed = try await client.confirmTokenAllowance(
    transactionHash: result.transactionHash,
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: rainOperatorAddress
)
```

Sandbox runs on Base Sepolia and Arbitrum Sepolia, production on Base and Arbitrum; USDC on all four
is in the built-in token registry. Auth Pull remains disabled until `authPullConfig(_:)` supplies
Rain's trusted operator and canonical token targets, and the SDK rejects any different chain, token,
or spender before a wallet prompt. `.custom` fails closed unless it receives an explicit custom Auth
Pull configuration.

Gate your UI on `rain.authPullChainIds` (also on `RainClient`), which is what the approval guard
enforces: the configuration narrowed to chains with an RPC endpoint.
`RainAuthPullChains.sandbox` / `.production` answer for an environment and are the wider sets — use
them only before an SDK exists. `RainTokenAllowance.rawAmount` is the exact base-unit value and the one to
compare against; `decimalAmount` is for display and rounds past 38 significant digits, so gate on
`isUnlimited` before rendering a number. Full guide: [Auth Pull](docs/AUTH_PULL.md).

### 14. QR code generation

Returns PNG `Data` encoding any address — pass `nil` (or omit it) for the wallet's own address.

```swift
// The wallet's own address, 256 px, default colours.
let walletPNG = try await client.generateAddressQRCode()

// A specific address — e.g. the Solana account, or a Rain collateral deposit address.
let depositPNG = try await client.generateAddressQRCode(address: contract.depositAddress)

// Full control over size and colours.
let large = try await client.generateAddressQRCode(
    address: try await client.getWalletAddress(chainId: RainChain.solanaDevnet),
    dimension: 500,
    backgroundColor: nil, // defaults applied when nil
    foregroundColor: nil
)
let image = UIImage(data: walletPNG)
```

For a short overview of all public methods, see [Method overview](docs/METHODS.md). For the Auth
Pull approval flow end to end, see [Auth Pull](docs/AUTH_PULL.md).

## License

See the [LICENSE](LICENSE) file for details.
