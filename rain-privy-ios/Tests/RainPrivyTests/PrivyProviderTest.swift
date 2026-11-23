import Testing
import Foundation
import RainCore
@testable import RainPrivy

/// Descriptor coverage. `create(context:)` probes a live embedded wallet, so resolution is
/// exercised in `PrivyManagerTests` / `PrivyWalletProviderTests` through the
/// `PrivyWalletSource` seam instead.
@Suite("Privy Provider Tests")
struct PrivyProviderTest {

  @Test("descriptor advertises the privy id and capabilities")
  func descriptorAdvertisesIdAndCapabilities() {
    // id / capabilities are static descriptor knowledge — the vendor singleton is never touched.
    let provider = PrivyProvider(PrivyConfig(privy: UnimplementedPrivy()))
    #expect(provider.id == .privy)
    #expect(provider.capabilities == [.export, .recovery, .multiChain])
  }

  @Test("registering the Privy error mapper is idempotent")
  func errorMapperRegistrationIsIdempotent() {
    // Registers on first call; subsequent calls must be no-ops (no crash, no duplicate registration).
    PrivyErrorMapping.registerOnce()
    PrivyErrorMapping.registerOnce()
  }
}
