import Foundation

/// Registrable descriptor for a wallet provider — the outside-in plug point of the
/// ports-and-adapters design. A host constructs a concrete descriptor (e.g. `PortalProvider`,
/// `TurnkeyProvider`, `PrivyProvider`, or a custom one) with its config and registers it on
/// `RainSdk.builder()`. Core references only this abstraction, never a concrete vendor type.
///
/// A provider descriptor:
/// - `id` / `capabilities` are cheap and available before any wallet is materialized, so the
///   registry can resolve by id or by capability without constructing the provider.
/// - `create(context:)` lazily builds the vendor-backed `WalletProvider`, receiving the
///   shared vendor-free `ProviderContext`. It may probe the wallet and throw if unavailable.
public protocol ProviderDescriptor: Sendable {
  /// Stable identifier used to resolve this provider from the registry.
  var id: ProviderId { get }

  /// Optional capabilities this provider advertises (used by `RainSdk.first { }`).
  var capabilities: Set<Capability> { get }

  /// Lazily materializes the vendor-backed wallet provider. Called once per resolution and
  /// cached by `RainSdk`. Receives the shared, vendor-free infrastructure context.
  func create(context: ProviderContext) async throws -> any WalletProvider

  /// Releases whatever the descriptor holds open — session watchers, vendor clients, expiry
  /// hooks — so a discarded provider can never call back into the host. Called by
  /// ``RainSdk/close()`` for every registered descriptor, and by ``RainSdk/Builder/build()`` for a
  /// descriptor that a later `register` of the same id replaced. Idempotent. Defaults to a no-op.
  func close()
}

public extension ProviderDescriptor {
  var capabilities: Set<Capability> { [] }
  func close() {}
}
