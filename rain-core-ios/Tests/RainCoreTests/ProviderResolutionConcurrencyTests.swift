import Testing
import Foundation
@testable import RainCore

/// Regression tests for `RainSdk.provider(_:)` lazy resolution.
///
/// The registry must resolve each provider id exactly once even under a burst of concurrent
/// first-resolutions: `ProviderDescriptor.create(context:)` may fire vendor side effects (Portal's
/// `onPortalCreated` hook, Turnkey's wallet probe), so a double-create is a real defect. The old
/// implementation called `create()` outside the cache lock, so two concurrent misses both created;
/// the fix caches the in-flight resolution `Task` so all callers await one `create()`.
@Suite("Provider Resolution Concurrency Tests")
struct ProviderResolutionConcurrencyTests {

  /// Counts how many times `create()` runs, across concurrent callers.
  private actor CreateCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  /// `ProviderDescriptor` whose `create()` bumps a shared counter and sleeps briefly to widen the race
  /// window, then returns a fresh `StubWalletProvider`. Optionally fails to exercise retry.
  private final class CountingProvider: ProviderDescriptor, @unchecked Sendable {
    let id: ProviderId
    let counter: CreateCounter
    let failFirst: Bool
    private let failLock = NSLock()
    private var hasFailed = false

    init(id: ProviderId = .turnkey, counter: CreateCounter, failFirst: Bool = false) {
      self.id = id
      self.counter = counter
      self.failFirst = failFirst
    }

    var capabilities: Set<Capability> { [] }

    func create(context: ProviderContext) async throws -> any WalletProvider {
      await counter.increment()
      try? await Task.sleep(nanoseconds: 20_000_000) // 20ms — widen the concurrent-miss window
      if failFirst {
        let shouldFail: Bool = failLock.withLock {
          if hasFailed { return false }
          hasFailed = true
          return true
        }
        if shouldFail { throw RainError.internalError(details: "boom") }
      }
      return StubWalletProvider()
    }
  }

  private func makeSdk(_ provider: CountingProvider) throws -> RainSdk {
    try RainSdk.builder()
      .rpcEndpoints([NetworkConfig.testConfig(chainId: 1)])
      .register(provider)
      .build()
  }

  @Test("100 concurrent resolutions of the same id run create() exactly once")
  func testConcurrentResolveCreatesOnce() async throws {
    let counter = CreateCounter()
    let sdk = try makeSdk(CountingProvider(counter: counter))

    let clients = try await withThrowingTaskGroup(of: RainClient.self) { group in
      for _ in 0..<100 { group.addTask { try await sdk.provider(.turnkey) } }
      var out: [RainClient] = []
      for try await c in group { out.append(c) }
      return out
    }

    #expect(await counter.count == 1)          // no double-create
    #expect(clients.count == 100)
    // Every caller received the same cached client instance.
    let first = clients[0] as? RainSdkManager
    #expect(first != nil)
    #expect(clients.allSatisfy { ($0 as? RainSdkManager) === first })
  }

  @Test("resolution is cached: a later resolve reuses the client without re-creating")
  func testResolveCachesAcrossCalls() async throws {
    let counter = CreateCounter()
    let sdk = try makeSdk(CountingProvider(counter: counter))

    let a = try await sdk.provider(.turnkey)
    let b = try await sdk.provider(.turnkey)

    #expect(await counter.count == 1)
    #expect((a as? RainSdkManager) === (b as? RainSdkManager))
  }

  @Test("a failed resolution is not cached — a later resolve retries and succeeds")
  func testFailedResolutionEvictedAndRetryable() async throws {
    let counter = CreateCounter()
    let sdk = try makeSdk(CountingProvider(counter: counter, failFirst: true))

    await #expect(throws: RainError.self) { _ = try await sdk.provider(.turnkey) }
    // Second attempt must be allowed to run create() again (failure wasn't cached).
    _ = try await sdk.provider(.turnkey)

    #expect(await counter.count == 2)
  }
}
