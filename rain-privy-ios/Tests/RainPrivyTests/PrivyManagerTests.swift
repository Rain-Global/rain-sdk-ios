import Testing
import Foundation
import PrivySDK
import RainCore
@testable import RainPrivy

/// Wallet resolution semantics, raw-error propagation, switch-then-broadcast ordering, the
/// resolve-once address cache, and send serialization.
@Suite("Privy Manager Tests")
struct PrivyManagerTests {
  private static let wallet = "0x000000000000000000000000000000000000dEaD"
  private static let rpc = "https://rpc.example/1"

  // MARK: - resolveWallet

  @Test("throws tokenExpired when no authenticated user")
  func noUserThrowsTokenExpired() async {
    let manager = PrivyManager(source: FakeWalletSource(wallets: nil))
    await #expect(throws: RainError.tokenExpired) {
      _ = try await manager.address(override: nil)
    }
  }

  @Test("throws walletUnavailable when user has no embedded wallet")
  func noWalletThrowsWalletUnavailable() async {
    let manager = PrivyManager(source: FakeWalletSource(wallets: []))
    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.address(override: nil)
    }
  }

  @Test("signing resolves the override case-insensitively")
  func overrideMatchesCaseInsensitively() async throws {
    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xSIG"))
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))
    // Override in a different case than the wallet's stored address still resolves.
    let signature = try await manager.signTypedData(
      walletAddress: Self.wallet.lowercased(), typedDataJson: "{}"
    )
    #expect(signature == "0xSIG")
  }

  @Test("throws walletUnavailable when the override matches no wallet")
  func overrideMismatchThrowsWalletUnavailable() async {
    let signer = FakeSigner(address: Self.wallet)
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))
    await #expect(throws: RainError.walletUnavailable()) {
      _ = try await manager.signTypedData(walletAddress: "0xNOPE", typedDataJson: "{}")
    }
  }

  @Test("falls back to the first wallet when no override is given")
  func firstWalletFallback() async throws {
    let first = FakeSigner(address: Self.wallet)
    let second = FakeSigner(address: "0xSECOND")
    let manager = PrivyManager(source: FakeWalletSource(wallets: [first, second]))
    #expect(try await manager.address(override: nil) == Self.wallet)
  }

  @Test("address override returns without a Privy lookup")
  func overrideSkipsLookup() async throws {
    let source = FakeWalletSource(wallets: nil) // would throw tokenExpired if consulted
    let manager = PrivyManager(source: source)
    #expect(try await manager.address(override: "0xOVERRIDE") == "0xOVERRIDE")
    #expect(source.lookups == 0)
  }

  @Test("concurrent first-access callers share one address resolution")
  func addressResolvesOnce() async throws {
    let signer = FakeSigner(address: Self.wallet)
    let source = FakeWalletSource(wallets: [signer], lookupDelayNs: 50_000_000)
    let manager = PrivyManager(source: source)

    async let a = manager.address(override: nil)
    async let b = manager.address(override: nil)
    let (first, second) = try await (a, b)

    #expect(first == Self.wallet)
    #expect(second == Self.wallet)
    #expect(source.lookups == 1)
  }

  // MARK: - Sign / send

  @Test("signTypedData returns the provider signature via eth_signTypedData_v4")
  func signTypedDataDelegates() async throws {
    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xSIG"))
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))

    let signature = try await manager.signTypedData(walletAddress: Self.wallet, typedDataJson: "{}")

    #expect(signature == "0xSIG")
    #expect(signer.events == ["request:eth_signTypedData_v4"])
  }

  @Test("sendTransaction switches to the chain's RPC then broadcasts")
  func sendSwitchesThenBroadcasts() async throws {
    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xHASH"))
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))

    let hash = try await manager.sendTransaction(
      walletAddress: Self.wallet,
      rpcUrl: Self.rpc,
      chainId: 1,
      transaction: EthereumRpcRequest.UnsignedEthTransaction(
        from: Self.wallet, to: "0xTO", value: .hexadecimalNumber("0x1"), chainId: .int(1)
      )
    )

    #expect(hash == "0xHASH")
    #expect(signer.events == ["switch:1", "request:eth_sendTransaction"])
  }

  @Test("concurrent sends to different chains serialize (no switch/request interleave)")
  func sendsSerialize() async throws {
    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xHASH"))
    signer.requestDelayNs = 50_000_000 // widen the window an interleave would need
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))

    func tx(_ chainId: Int) -> EthereumRpcRequest.UnsignedEthTransaction {
      EthereumRpcRequest.UnsignedEthTransaction(
        from: Self.wallet, to: "0xTO", value: .hexadecimalNumber("0x1"), chainId: .int(chainId)
      )
    }
    async let a = manager.sendTransaction(
      walletAddress: Self.wallet, rpcUrl: Self.rpc, chainId: 1, transaction: tx(1))
    async let b = manager.sendTransaction(
      walletAddress: Self.wallet, rpcUrl: Self.rpc, chainId: 2, transaction: tx(2))
    _ = try await (a, b)

    // Each send's switch must be immediately followed by its own request — a stateful provider
    // interleaving (switch, switch, request, request) would broadcast on the wrong chain.
    let events = signer.events
    #expect(events.count == 4)
    #expect(events[0].hasPrefix("switch:"))
    #expect(events[1] == "request:eth_sendTransaction")
    #expect(events[2].hasPrefix("switch:"))
    #expect(events[3] == "request:eth_sendTransaction")
    #expect(events[0] != events[2]) // both chains actually went through
  }

  // MARK: - Raw error propagation

  @Test("request bubbles the raw provider failure rather than wrapping it")
  func requestBubblesRawError() async {
    let raw = NSError(
      domain: "PrivyTest", code: 4001,
      userInfo: [NSLocalizedDescriptionKey: "user rejected the request"]
    )
    let signer = FakeSigner(address: Self.wallet, requestResult: .failure(raw))
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))

    do {
      _ = try await manager.signTypedData(walletAddress: Self.wallet, typedDataJson: "{}")
      Issue.record("expected the raw provider error to propagate")
    } catch {
      // Must NOT be pre-wrapped in RainError — core's `RainError.from(underlying:)`
      // short-circuits on RainError, so pre-wrapping would hide classification.
      #expect(!(error is RainError))
      #expect((error as NSError).domain == "PrivyTest")
      #expect((error as NSError).code == 4001)
    }
  }

  @Test("send failure releases the lock for the next send")
  func failedSendReleasesLock() async throws {
    let signer = FakeSigner(
      address: Self.wallet,
      requestResult: .failure(NSError(domain: "PrivyTest", code: -1))
    )
    let manager = PrivyManager(source: FakeWalletSource(wallets: [signer]))
    let tx = EthereumRpcRequest.UnsignedEthTransaction(
      from: Self.wallet, to: "0xTO", value: .hexadecimalNumber("0x1"), chainId: .int(1)
    )

    await #expect(throws: Error.self) {
      _ = try await manager.sendTransaction(
        walletAddress: Self.wallet, rpcUrl: Self.rpc, chainId: 1, transaction: tx)
    }

    // A failed send must not leave the lock held.
    signer.requestResult = .success("0xHASH")
    let hash = try await manager.sendTransaction(
      walletAddress: Self.wallet, rpcUrl: Self.rpc, chainId: 1, transaction: tx)
    #expect(hash == "0xHASH")
  }

  @Test("eviction drops cached accounts so the next resolution re-reads Privy")
  func evictionDropsCaches() async throws {
    let source = FakeWalletSource(wallets: [FakeSigner(address: Self.wallet)])
    let manager = PrivyManager(source: source)

    _ = try await manager.address(override: nil)
    _ = try await manager.address(override: nil)
    #expect(source.lookups == 1)

    await manager.evictCachedAccounts()

    _ = try await manager.address(override: nil)
    #expect(source.lookups == 2)
  }

  @Test("eviction during an in-flight resolution does not repopulate the cache")
  func evictionMidFlightDoesNotRepopulate() async throws {
    let source = FakeWalletSource(
      wallets: [FakeSigner(address: Self.wallet)],
      lookupDelayNs: 100_000_000
    )
    let manager = PrivyManager(source: source)

    // The resolution suspends mid-flight; the eviction (session death) lands while it waits.
    let inFlight = Task { try await manager.address(override: nil) }
    try await Task.sleep(nanoseconds: 20_000_000)
    await manager.evictCachedAccounts()
    _ = try await inFlight.value

    // The stale result must not have been cached: the next call re-resolves.
    _ = try await manager.address(override: nil)
    #expect(source.lookups == 2)
  }
}
