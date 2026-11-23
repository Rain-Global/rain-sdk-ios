// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// MARK: - Rain SDK (modular)
//
// One package, one product per wallet provider — a client links only the providers it uses:
//   • rain-core-ios    — vendor-free port + registry + Rain domain logic (no wallet vendor SDKs)
//   • rain-turnkey-ios — the Turnkey adapter (RainCore + tkhq/swift-sdk)
//   • rain-portal-ios  — the Portal MPC adapter (RainCore + PortalSwift)
//   • rain-privy-ios   — the Privy embedded-key adapter (RainCore + the Privy iOS SDK)
//
// Products are named for the SDK (`rain-portal-ios`), matching the Android artifact ids; the
// importable module keeps its Swift name (`import RainPortal`). Each adapter re-exports
// `RainCore`, so one import per provider is enough.
//
// The 1.x `RainSDK` migration umbrella has been removed — link the provider product you use.

let package = Package(
  name: "RainSDK",
  platforms: [
    .iOS(.v17)
  ],
  products: [
    .library(
      name: "rain-core-ios",
      targets: ["RainCore"]
    ),
    .library(
      name: "rain-turnkey-ios",
      targets: ["RainTurnkey"]
    ),
    .library(
      name: "rain-portal-ios",
      targets: ["RainPortal"]
    ),
    .library(
      name: "rain-privy-ios",
      targets: ["RainPrivy"]
    ),
    .library(
      name: "rain-wallet-ios",
      targets: ["RainWallet"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/tkhq/swift-sdk.git", exact: "4.0.0"),
    .package(url: "https://github.com/Boilertalk/Web3.swift.git", exact: "0.8.8"),
    // Declared directly because every module `import BigInt`s. Pinned to 5.3.0 — not by choice:
    // tkhq/swift-sdk 4.0.0 → anquii/Base58 1.0.0 hard-pins `.exact("5.3.0")`, so it is the only
    // version any consumer can resolve. 5.3.0 predates `Sendable` on `BigUInt` (added in 5.4.0);
    // RainCore fills the gap with a retroactive conformance (`BigInt+Sendable.swift`). Lift the pin
    // and delete that file together, once Turnkey's graph allows a newer BigInt.
    .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.3.0"),
    .package(url: "https://github.com/dagronf/QRCode", exact: "28.0.2"),
    .package(url: "https://github.com/portal-hq/PortalSwift.git", exact: "7.3.0"),
    // Floor 2.16.2: earlier binaries bundle an unsigned SwiftyJSON and App Store Connect rejects
    // the host app with ITMS-91065 (hit on the demo's first TestFlight upload, 2026-09-29).
    .package(url: "https://github.com/privy-io/privy-ios", from: "2.16.2"),
  ],
  targets: [
    // Vendor-free core: no wallet vendor SDKs on this target.
    .target(
      name: "RainCore",
      dependencies: [
        .product(name: "BigInt", package: "BigInt"),
        .product(name: "QRCode", package: "QRCode"),
        .product(name: "Web3", package: "Web3.swift"),
        .product(name: "Web3PromiseKit", package: "Web3.swift"),
        .product(name: "Web3ContractABI", package: "Web3.swift"),
      ],
      path: "rain-core-ios/Sources/RainCore",
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "RainCoreTests",
      dependencies: ["RainCore"],
      path: "rain-core-ios/Tests/RainCoreTests"
    ),

    .target(
      name: "RainTurnkey",
      dependencies: [
        "RainCore",
        .product(name: "BigInt", package: "BigInt"),
        .product(name: "TurnkeySwift", package: "swift-sdk"),
        .product(name: "TurnkeyHttp", package: "swift-sdk"),
        .product(name: "TurnkeyTypes", package: "swift-sdk"),
        .product(name: "TurnkeyCrypto", package: "swift-sdk"),
        .product(name: "TurnkeyPasskeys", package: "swift-sdk"),
        // Managed auth signs rain-api's client message with the per-attempt key (`Stamper`).
        .product(name: "TurnkeyStamper", package: "swift-sdk"),
      ],
      path: "rain-turnkey-ios/Sources/RainTurnkey"
    ),
    .testTarget(
      name: "RainTurnkeyTests",
      dependencies: ["RainTurnkey"],
      path: "rain-turnkey-ios/Tests/RainTurnkeyTests"
    ),

    // The Rain-branded wallet: a wallet-neutral surface over the managed wallet backend.
    // Depends on RainTurnkey internally but never re-exports it.
    .target(
      name: "RainWallet",
      dependencies: ["RainTurnkey"],
      path: "rain-wallet-ios/Sources/RainWallet"
    ),
    .testTarget(
      name: "RainWalletTests",
      dependencies: ["RainWallet"],
      path: "rain-wallet-ios/Tests/RainWalletTests"
    ),

    .target(
      name: "RainPortal",
      dependencies: [
        "RainCore",
        .product(name: "BigInt", package: "BigInt"),
        .product(name: "PortalSwift", package: "PortalSwift"),
      ],
      path: "rain-portal-ios/Sources/RainPortal"
    ),
    .testTarget(
      name: "RainPortalTests",
      dependencies: ["RainPortal"],
      path: "rain-portal-ios/Tests/RainPortalTests"
    ),

    // The Privy vendor SDK is owned here so core never imports Privy — linking this module is
    // what pulls it onto a client's graph.
    .target(
      name: "RainPrivy",
      dependencies: [
        "RainCore",
        .product(name: "BigInt", package: "BigInt"),
        .product(name: "Privy", package: "privy-ios"),
      ],
      path: "rain-privy-ios/Sources/RainPrivy"
    ),
    .testTarget(
      name: "RainPrivyTests",
      dependencies: ["RainPrivy"],
      path: "rain-privy-ios/Tests/RainPrivyTests"
    ),

  ]
)
