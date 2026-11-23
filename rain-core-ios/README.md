# RainCore

The vendor-free core of the modular Rain iOS SDK — the "one core" in *one core, many providers*.

Contains:

- The **`WalletProvider`** port (the capability the SDK needs from any wallet).
- The **`ProviderDescriptor`** descriptor + **`RainSdk`** builder/registry (`RainSdk.builder().register(…).build()`, resolve via `provider(_:)` / `first { }`).
- The **`Capability`** model and **`ProviderId`**.
- All Rain domain logic — EIP-712 message building, collateral withdraw flow, transaction orchestration, chain readers, token metadata store.

`RainCore` has **no wallet-vendor dependencies** — Turnkey, Portal, and Privy each ship as their
own adapter product (`rain-turnkey-ios`, `rain-portal-ios`, `rain-privy-ios`), and every adapter
re-exports `RainCore`. Link `rain-core-ios` alone for wallet-agnostic building or a custom
`WalletProvider`:

```swift
import RainCore

// Wallet-agnostic: build EIP-712 messages / withdraw calldata with no provider resolved.
let rain = try RainSdk.builder()
    .rpcEndpoints([43114: "https://avalanche-c-chain-rpc.publicnode.com"])
    .build()

let (message, salt) = try await rain.buildEIP712Message(
    chainId: 43114, walletAddress: "0x…", assetAddresses: addresses,
    amount: 100, decimals: 6, nonce: nil
)
```

To add Portal, depend on `RainPortal` (which pulls `RainCore` transitively). To add Privy, depend on `RainPrivy`.
