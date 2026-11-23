# Auth Pull integration (iOS)

Auth Pull lets a card authorization draw funds directly from the user's wallet into their Rain
collateral contract. When an authorization arrives for a user whose tenant is enabled for Auth
Pull, Rain pulls the full amount in USDC from that wallet before approving the authorization.

**What the SDK does:** sets and inspects the ERC-20 allowance that makes the pull possible.
**What the SDK does not do:** the pull itself. That is Rain's `transferFrom`, executed server-side
with no app involvement.

Four methods cover the whole surface:

| Method | Purpose |
|---|---|
| `approveTokenAllowance(chainId:contractAddress:spender:amount:)` | Approve the user's collateral contract to spend the user's USDC |
| `getTokenAllowance(chainId:contractAddress:spender:owner:)` | Read the current allowance |
| `estimateApprovalFee(chainId:contractAddress:spender:amount:)` | Price the approval before submitting it |
| `confirmTokenAllowance(transactionHash:chainId:contractAddress:spender:amount:owner:)` | Wait for a successful receipt and read back the resulting allowance |

See [Method reference](METHODS.md#approvetokenallowancechainidcontractaddressspenderamount)
for full parameter tables.

---

## Prerequisites

Before an authorization can pull:

1. The tenant is enabled for Auth Pull — contact Rain.
2. The user has a wallet address associated with their Rain account on a supported chain, and that
   wallet is an admin of the user's collateral contract there.
3. That wallet holds USDC on the supported chain.
4. That wallet holds enough native gas to pay for the approval transaction.
5. That wallet has approved the user's collateral contract — the part this SDK performs.

For step 5, the SDK also needs `RainSdk.Builder.authPullConfig(_:)`: the canonical token contract
per chain. Every Auth Pull method fails closed without it.

## Supported chains and assets

USDC is the only asset supported while Auth Pull is in beta.

### Sandbox

| Chain | Chain ID | USDC |
|---|---|---|
| Base Sepolia | `84532` (`RainChain.baseSepolia`) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Arbitrum Sepolia | `421614` (`RainChain.arbitrumSepolia`) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |

### Production

| Chain | Chain ID | USDC |
|---|---|---|
| Base | `8453` (`RainChain.baseMainnet`) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Arbitrum | `42161` (`RainChain.arbitrumMainnet`) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |

All four are in the SDK's built-in token registry, so balance and allowance reads resolve USDC's
decimals with no `registerTokens` call and no on-chain lookup. The public API is
token-address-based rather than USDC-only, so it keeps working when Rain adds assets.

`RainAuthPullChains` holds these two sets:

```swift
RainAuthPullChains.sandbox      // [84532, 421614]
RainAuthPullChains.production   // [8453, 42161]
```

**To gate UI, use `authPullChainIds` instead.** The environment's set is the wider answer; what a
built SDK will accept is that set narrowed by the host's `RainAuthPullConfig` and by which chains
have an RPC endpoint. Both `RainSdk` and `RainClient` expose the resolved one, so a screen holding
either can offer exactly the chains an approval will succeed on:

```swift
let enabled = rain.authPullChainIds          // or: client.authPullChainIds
guard enabled.contains(chainId) else { return }   // don't offer Auth Pull here
```

The two differ whenever a configuration is narrower than its environment, an RPC endpoint is
missing, or the configuration is `.custom` — whose chains only the resolved set can enumerate.
Reach for the static sets only where no SDK exists yet, such as a chain picker built at startup.

## Environments must match

The sandbox and production chain sets are disjoint, and the USDC addresses differ between them. Approving on the wrong environment's chain still mines a perfectly valid allowance —
one that no authorization will ever draw on, and on mainnet at real cost to the user. `approve`
succeeds against any address, so nothing downstream would catch it.

The SDK therefore rejects mismatched chain and token targets locally with `invalidConfig`
(`RAIN_102`), before wallet access.

The SDK has no Rain-environment setting of its own; the `RainAuthPullConfig` you pass *is* the
environment (`.sandbox` / `.production`), and its chains must belong to that environment's set.
Auth Pull is disabled until the builder receives one:

```swift
let rain = try RainSdk.builder()
    .rpcEndpoints(rpcEndpoints)
    .authPullConfig(.sandbox())
    .register(provider)
    .build()
```

The SDK then requires the canonical USDC contract on every approval, allowance read,
confirmation, and fee estimate. A non-standard deployment (staging, a self-hosted gateway) uses
`RainAuthPullConfig.custom(tokenAddresses:)`, which may draw chains from either environment's set
but nothing outside them.

## The spender

The spender is the user's collateral contract on the chain: the `proxyAddress` that
`GET /v1/issuing/users/{userId}/contracts` returns, one per user and per chain. Take it from the
Rain API, never from user input.

Before a non-zero approval or its fee estimate, the SDK asks the spender itself whether the wallet
is one of its admins (`isAdmin(wallet)`), and refuses unless it answers yes:

| Answer | Error |
|---|---|
| Not an admin | `walletNotAuthorized` (`RAIN_407`) |
| The spender is not a collateral contract (the call reverts, returns nothing, or returns a word other than 0 or 1) | `invalidConfig` (`RAIN_102`) |
| The read got no answer | `networkError` (`RAIN_301`) |
| The node answered with an error that is not a revert, or a result that does not decode | `internalError` (`RAIN_502`) |

That read stops a typo, a plain address and a contract of another kind. It does not prove that
Rain issued the contract. A zero amount (a revoke), `getTokenAllowance` and
`confirmTokenAllowance` accept any well-formed, non-zero spender and skip the read, so a wallet can
still see and revoke an approval to Rain's former operator. A mixed-case spender must carry a valid
EIP-55 checksum.

A wallet that approved Rain's operator on a version before `5.0.0-beta.2` approves its collateral contract as well,
and revokes the operator with a zero amount only when Rain says so. The SDK cannot grant the
operator a new allowance.

## Funding the wallet in sandbox

Testnet USDC comes from the [Circle faucet](https://faucet.circle.com/) — choose Base Sepolia or
Arbitrum Sepolia and paste the wallet address associated with the Rain user. Native gas comes from
the usual chain faucet. Without native gas the approval cannot be submitted at all.

---

## Integration

### 1. Read the current allowance

Cheap and free — do this before prompting the user, so a wallet that is already approved does not
pay for a redundant transaction.

```swift
let allowance = try await client.getTokenAllowance(
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: proxyAddress
)

if allowance.isUnlimited {
    // Nothing to do.
} else if allowance.covers(expectedSpend) {
    // Enough for now.
} else {
    // Prompt for an approval.
}
```

`rawAmount` is the exact base-unit value and is never lossy — compare against it. `decimalAmount`
and `formatted` are for display and round past `Decimal`'s 38 significant digits, so an unlimited
allowance formats as a meaningless 72-digit USDC figure. Gate on `isUnlimited` and show a label
instead. `covers(_:)` answers from `rawAmount`, and returns `false` for an amount it cannot
represent at all (negative, or finer than the token's scale) — so `false` means "do not rely on
this allowance", not "approve more".

`isUnlimited` is exact (`rawAmount == uint256` max). Some tokens decrement even a max allowance on
every `transferFrom`, so a wallet approved as unlimited can later report `false` while still
holding an enormous allowance. Treat `false` as "compare `rawAmount` against what you need", not
as "must re-approve".

### 2. Estimate the fee (optional)

```swift
let fee = try await client.estimateApprovalFee(
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: proxyAddress
)
// e.g. 0.00042 ETH
```

Nothing is broadcast and the user is not prompted. The estimate prices the exact calldata the
approval would send.

### 3. Approve

```swift
// Unlimited — Rain's recommendation, so the user never has to re-approve.
let result = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: proxyAddress
)
print(result.transactionHash)
```

An omitted (or `nil`) `amount` means unlimited. Pass a `Decimal` to cap the allowance, and `0` to
revoke:

```swift
// Cap at 250 USDC.
_ = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: proxyAddress,
    amount: 250
)

// Revoke.
_ = try await client.approveTokenAllowance(
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: proxyAddress,
    amount: 0
)
```

A capped approval is a standing balance, not a per-authorization budget: each pull consumes part
of it, and once it runs out the next authorization is declined. Unlimited avoids that failure mode.

**Changing a non-zero allowance.** The call writes the new value straight over the old one. USDC
accepts that on all four Auth Pull chains, but some ERC-20s (USDT and its clones) revert unless the
allowance is set to `0` first — approve `0`, wait for it to mine, then approve the new amount. The
same rewrite is also the classic approval race: between the two transactions a spender that already
holds an allowance can spend the old value and then the new one. Neither applies to a collateral
contract on USDC today; both become live questions if Auth Pull adds an asset.

### 4. Confirm

`transactionHash` means submitted, not mined. Use `confirmTokenAllowance` before treating the user
as ready; it polls for a successful receipt (up to 60s, retrying transient RPC failures along the
way) and reads back the resulting allowance at the block that receipt landed in, so a load-balanced
endpoint answering from a replica that is still behind cannot confirm against pre-approval state:

```swift
let updated = try await client.confirmTokenAllowance(
    transactionHash: result.transactionHash,
    chainId: RainChain.baseSepolia,
    contractAddress: usdcAddress,
    spender: proxyAddress,
    amount: 250   // omit for the unlimited approval
)
```

**The result can legitimately be lower than what you approved.** Auth Pull spends this very
allowance, and USDC decrements it on every `transferFrom` — including a `uint256` max one, which
Circle's token does not special-case. An authorization that pulls between the receipt and the read
therefore leaves less than was approved, and that is a success, not a failure. Compare `rawAmount`
(or `covers(_:)`) against what you still need rather than against what you asked for.

Two outcomes are genuine failures and throw: a mined revoke that left a spendable allowance, and a
mined approval whose allowance is still zero — the shape a wrong owner, token, or spender produces.
A reverted receipt throws `transactionSimulationFailed`; exhausting the poll window throws
`networkError`, which means "not confirmed yet", not "failed" — re-read the allowance rather than
re-approving.

Once the allowance is in place, no further app action is required. Rain pulls the full
authorization amount into the user's collateral contract at authorization time.

---

## Amounts and decimals

Amounts are human-readable `Decimal`s, matching `sendToken`. The SDK scales by the token's decimals
and **rejects** an amount finer than the token supports (`invalidAmount`, `RAIN_406`) rather than
truncating it — `1.2345678` on 6-decimal USDC is an error, not `1.234567`.

**There is no `decimals` parameter.** Auth Pull resolves the scale itself — trusted registry
metadata first, then a one-time strict on-chain `decimals()` read — and takes no override, because a
caller-supplied scale is exactly the input that turns a 250 USDC approval into 250 million. An
unlimited approval skips resolution entirely; `uint256` max needs no scaling.

**The approval path never guesses a scale.** Elsewhere in the SDK a failed `decimals()` read falls
back to 18, which misreports a balance. Here the same guess against a 6-decimal token would approve
10^12 times the intended amount — and `approve` succeeds regardless of the wallet's balance, so
nothing downstream would catch it. An unresolvable token therefore throws `tokenNotFound`
(`RAIN_102`). USDC on all four Auth Pull chains ships in the registry, so this only fires for a
token whose `decimals()` read fails — register it up front with `registerTokens` if you hit it.

## Provider support

| Provider | Approve / allowance / fee estimate | Notes |
|---|---|---|
| **Portal** | Supported | Broadcast goes through Portal's generic transaction path; its `eth_call` pre-simulation applies to approvals unchanged, so a doomed approval fails as `transactionSimulationFailed` before broadcast. |
| **Privy** | Supported | Same generic path (`eth_call` simulation → `switchChain` → `eth_sendTransaction`), carrying the approve calldata unchanged. |
| **Turnkey** | Supported | Approvals ride the same signed-transaction pipeline as any other ERC-20 send; no Turnkey-specific gating is needed. |

No provider needed a bespoke approval path, so no capability gate exists for this feature. The
allowance value itself is read over the SDK's own configured RPC (`eth_call`), never through the
wallet provider, so it works on any provider and on any configured, trusted Auth Pull chain. The
provider is asked for one thing: the wallet address to read the allowance *for*, and only when
`owner` is omitted — pass `owner` explicitly and the read touches no wallet at all.

## Failure modes

| Code | Case | When |
|---|---|---|
| `RAIN_102` | `invalidConfig(details:)` | Auth Pull is not configured, the token differs from the trusted one, malformed input (a spender with a bad checksum or the zero address included), wrong chain/environment, a spender that is not a collateral contract (non-zero approval or estimate), or the token reports `decimals` outside 0...77. Local configuration failures occur before wallet access. |
| `RAIN_102` | `tokenNotFound(token:chainId:)` | The token's decimals could not be established (not in the registry and its `decimals()` read failed), so a capped amount cannot be scaled safely. Never raised for an unlimited approval. |
| `RAIN_301` | `networkError(underlying:)` | A network failure on an RPC read (the spender's `isAdmin` read included), or a mined approval whose allowance could not be read back within the 60s window. |
| `RAIN_302` | `transactionPending(statusId:)` | `confirmTokenAllowance` exhausted its 60s window without a receipt; `statusId` is the transaction hash. Not confirmed yet — re-read the allowance or confirm again, don't re-approve. |
| `RAIN_401` | `userRejected` | The user declined the signature in the wallet UI. |
| `RAIN_402` | `insufficientFunds(required:available:)` | Not enough native gas to submit the approval. |
| `RAIN_403` | `transactionSimulationFailed(underlying:)` | Preflight simulation reverted (providers that simulate), or `confirmTokenAllowance` found a mined receipt that reverted. |
| `RAIN_404` | `walletUnavailable(details:)` | The wallet provider has no address — the user has not connected or created a wallet. Reachable on any approval or fee estimate (they resolve the `from` address), and on an allowance read or confirmation with `owner` omitted. |
| `RAIN_406` | `invalidAmount(amount:reason:)` | Negative amount, more decimal places than the token supports, or a value past `uint256` max. |
| `RAIN_407` | `walletNotAuthorized(walletAddress:proxyAddress:)` | A non-zero approval or its fee estimate: the spender answered that the wallet is not one of its admins. |
| `RAIN_501` | `providerError(underlying:)` | The wallet provider failed for its own reasons. |
| `RAIN_502` | `internalError(details:)` | The spender's `isAdmin` read got a node error that is not a revert, or an answer that does not decode; ABI encoding failed, a Solana chain ID was passed (approvals are EVM-only), the provider cannot estimate fees, or a mined allowance contradicted the request (revoke left a spendable allowance, or an approval left zero). |

Errors are always `RainError`; vendor errors are wrapped, never surfaced raw.

## Not covered

EIP-2612 `permit` (gasless) approvals, gasless / sponsored approval transactions, non-USDC assets,
and account-abstraction flows are out of scope for this release.

## See also

- [Method reference](METHODS.md)
- [Demo app](../Example/RainSDKDemo/README.md) — the **Auth Pull** screen runs this whole flow
- Rain's [Auth Pull documentation](https://docs.rain.xyz/docs/real-time-funding)
