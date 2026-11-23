# Rain SDK Demo App (iOS)

A SwiftUI sample that exercises the public Rain SDK surface with a real wallet provider: connect a
wallet, read balances, send tokens, withdraw collateral, approve the user's collateral contract for Auth Pull, and list
transaction history.

---

## Requirements

- Xcode 16+ (Swift 6.1)
- iOS 17.6+ simulator or device
- Rain SDK packages resolved from this repo (`rain-core-ios`, `rain-portal-ios`, `rain-privy-ios`)

## How to run

1. Open `Example/RainSDKDemo/RainSDKDemo.xcodeproj`.
2. Select the **RainSDKDemo** scheme and a simulator.
3. Run (⌘R).

---

## Screens

| Screen | What it exercises |
|---|---|
| **Home** | Provider choice (Portal / Turnkey / Privy), Rain API credentials, auth, `RainSdk` build, active-chain dropdown, feature grid |
| **Wallet & QR** 💳 | `getWalletAddress(chainId:)` and the collateral deposit address from the demo's `RainApiClient` (Rain API — a host call, not SDK), each with a QR code from `generateAddressQRCode(address:)` |
| **Balances** 💰 | Collateral balances (Rain API) and the wallet's own native + auto-discovered token balances (`getBalance`, `getTokenBalances`) |
| **Send Tokens** 📤 | `sendNative` and `sendToken` (ERC-20 on EVM, SPL on Solana) |
| **Withdraw** 🏦 | admin signature from the demo's `RainApiClient`, then `withdrawCollateral` (build, sign, submit), incl. Withdraw Maximum |
| **Auth Pull** 🔐 | `getTokenAllowance`, `approveTokenAllowance` (unlimited / capped / revoke), `confirmTokenAllowance`, and `estimateApprovalFee` with the user's collateral contract from the demo's `RainApiClient` as the spender (so the screen needs the Rain API key), against the token the SDK was built with (see `SampleEnvironment.authPullConfig`) |
| **History** 📜 | `getTransactions(chainId:limit:offset:order:)`, latest 20 newest-first, with SEND / RECEIVE / SELF labels |

Every feature screen reads the chain picked in the **Active wallet** dropdown on Home, so switching
networks needs no re-initialization: the SDK is built with all chains' RPC endpoints at once (see
`WalletChain.networkConfigs`).

## Networks

`WalletChain` defines the four demo networks — Avalanche Fuji, Base Sepolia, Arbitrum Sepolia, and
Solana devnet — along with each one's RPC URL, native symbol, explorer links, default token /
recipient, and address validation. Portal holds no Solana account, so selecting Portal restricts the
dropdown to the EVM chains.

Auth Pull runs on Base Sepolia and Arbitrum Sepolia in sandbox; the Auth Pull screen gates on the
resolved client's `authPullChainIds` and disables itself on the other two. Get testnet USDC from the [Circle faucet](https://faucet.circle.com/),
and native gas from the usual chain faucet.

## Providers

Auth is the host app's responsibility; the SDK only wants an authenticated provider handle. Both
sample auth drivers live in `Core/Services` and are reference code you would write yourself:

- **Portal** — paste a Portal session token on Home and tap *Initialize SDK*.
- **Turnkey** (`TurnkeyAuthSample`) — parent organization ID + auth proxy config ID + email OTP.
  Sign-up and login are handled by `completeOtp`; an EVM and a Solana wallet are provisioned if the
  sub-org lacks them.
- **Privy** (`PrivyAuthSample`) — app ID + app client ID + email OTP; embedded Ethereum and Solana
  wallets are created on first sign-in.

For Turnkey and Privy, a session restored from a previous run is only reused when it belongs to the
email being signed in — otherwise the sample logs out and runs the full OTP flow.

Rain API credentials (program `Api-Key` + Rain `userId`) are separate from the wallet provider: they
authenticate the contract and withdrawal-signature calls, and are entered in their own card on Home.
Nothing is persisted — the fields are re-entered each launch.

## Notes

- **Portal wallet recovery** is unavailable: the Rain API has no backup-share endpoint yet (it is
  slated to move behind `POST /v1/issuing/users/{userId}/wallet`). The recover popup on the withdraw
  screen surfaces that state rather than calling a dead endpoint.
- **Solana history** rows carry the Turnkey activity id rather than a resolvable signature, so those
  rows are not linked to an explorer.

## Project structure

```
RainSDKDemo/
├── RainSDKDemoApp.swift            # App entry → HomeView
├── WalletChain.swift               # Demo networks, explorer links, address validation
├── SampleLog.swift                 # Console logging helper
├── Core/Services/
│   ├── RainSDKService.swift        # Holds the built RainSdk + resolved RainClient
│   ├── TurnkeyAuthSample.swift     # Turnkey email-OTP + wallet provisioning
│   └── PrivyAuthSample.swift       # Privy email-OTP + embedded wallets
├── Presentation/
│   ├── Home/                       # Provider setup, chain picker, feature grid
│   ├── WalletInfo/                 # Wallet & QR
│   ├── Balances/
│   ├── SendTokens/
│   ├── AuthPull/                   # Allowance display + collateral contract approval
│   ├── TransactionHistory/
│   └── CollateralWithdraw/         # Withdraw + Portal recover popup
└── Utils/                          # Formatting and keyboard helpers
```

For the full list of SDK methods and parameters, see [Method overview](../../docs/METHODS.md).
