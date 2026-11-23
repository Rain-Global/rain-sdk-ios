import BigInt

// `BigUInt` gained `Sendable` upstream in attaswift/BigInt 5.4.0, but the only version the SDK's
// dependency graph can resolve is 5.3.0 (tkhq/swift-sdk → anquii/Base58 hard-pins it; see
// Package.swift). Without this, every `Sendable` model carrying a raw amount (`Balance`,
// `RainTokenAllowance`, …) fails Swift 6 strict concurrency in any consumer that resolves fresh.
//
// The conformance is true, not a workaround: `BigUInt` is a value type whose storage is an
// enum of `UInt`s plus `[UInt]` — exactly what upstream declared in 5.4.0.
//
// Package.swift pins BigInt `exact: "5.3.0"`, which is what keeps this from ever becoming a
// redundant-conformance error. Delete this file in the same change that lifts that pin.
extension BigUInt: @retroactive @unchecked Sendable {}
