// RainTurnkey — the bring-your-own Turnkey wallet adapter.
//
// The host authenticates with its own Turnkey organization (passkeys / auth proxy / OAuth / OTP,
// via the Turnkey Swift SDK) and hands the authenticated `TurnkeyContext` to Rain:
//
//     import RainTurnkey   // surfaces RainCore too
//
//     let rain = try RainSdk.builder()
//         .rpcEndpoints([43114: "https://…"])
//         .register(TurnkeyProvider(TurnkeyConfig(turnkey: turnkeyContext)))
//         .build()
//     let client = try await rain.provider(.turnkey)
//
// RainCore is re-exported so a single `import RainTurnkey` gives the full SDK surface
// (`RainSdk`, `RainClient`, models, errors) — the same convention as the other adapter modules.

@_exported import RainCore
