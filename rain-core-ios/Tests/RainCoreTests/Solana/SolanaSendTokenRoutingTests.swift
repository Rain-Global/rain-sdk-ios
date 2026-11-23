import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

/// Pins what `RainSdkManager.sendToken` hands the Solana port. The `decimals` it passes is not
/// authoritative — the adapter reads the mint — but it is pinned so a host-written
/// adapter sees one contract on both platforms.
@Suite("Solana sendToken routing")
struct SolanaSendTokenRoutingTests {

  private static let mint = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  private static let recipient = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"

  private func manager(
    configs: [NetworkConfig] = TestFixtures.configs()
  ) -> (RainSdkManager, StubSolanaWalletProvider) {
    let stub = StubSolanaWalletProvider()
    let manager = RainSdkManager(
      walletProvider: stub,
      networkConfigs: configs,
      transactionBuilder: MockTransactionBuilderService(networkConfigs: configs),
      tokenStore: TokenMetadataStore(chainReader: EVMChainReader(networkConfigs: configs)),
      providerId: ProviderId("stub"),
      capabilities: []
    )
    return (manager, stub)
  }

  @Test("unspecified decimals reach the adapter as 0, not the EVM default")
  func unspecifiedDecimalsResolveToZero() async throws {
    let (manager, stub) = manager()

    _ = try await manager.sendToken(
      chainId: RainChain.solanaDevnet,
      contractAddress: Self.mint,
      to: Self.recipient,
      amount: 1.5,
      decimals: nil
    )

    #expect(stub.splTokenCalls.count == 1)
    #expect(stub.splTokenCalls.first?.decimals == 0)
  }

  @Test("a caller-supplied decimals passes through unchanged")
  func callerSuppliedDecimalsPassThrough() async throws {
    let (manager, stub) = manager()

    _ = try await manager.sendToken(
      chainId: RainChain.solanaDevnet,
      contractAddress: Self.mint,
      to: Self.recipient,
      amount: 1.5,
      decimals: 6
    )

    #expect(stub.splTokenCalls.first?.decimals == 6)
  }
}
