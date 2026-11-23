import Testing
import Foundation
import PrivySDK
@_spi(RainAdapter) @testable import RainCore
@testable import RainPrivy

/// Auth Pull approvals through `RainSdkManager` backed by the Privy provider — the same seam the
/// Portal and Turnkey approval tests cover. Uses the real `TransactionBuilderService`, so the
/// bytes that reach Privy's signer are pinned against the cross-platform goldens, not a stub.
@Suite("Privy Token Approval Tests")
struct PrivyTokenApprovalTests {
  private static let chainId = RainChain.baseSepolia
  private static let wallet = "0x000000000000000000000000000000000000dEaD"
  /// The collateral contract and canonical Base Sepolia USDC from the golden suite.
  private static let spender = "0x5a6E6b0d5Ea051CfFF9b3dcC2Aa8Dac226458f29"
  private static let usdc = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  private static let paddedSpender =
    "0000000000000000000000005a6e6b0d5ea051cfff9b3dcc2aa8dac226458f29"

  /// The `isAdmin(wallet)` read the SDK sends to the spender before a non-zero approval, answered
  /// "yes" so each test reaches the part it is about. `nil` for any other request.
  private static func adminAnswer(_ body: [String: Any]) -> Data? {
    guard body["method"] as? String == "eth_call",
          let call = (body["params"] as? [Any])?.first as? [String: Any],
          (call["to"] as? String)?.lowercased() == spender.lowercased()
    else { return nil }
    return RpcStub.result("0x" + String(repeating: "0", count: 63) + "1")
  }

  /// Counts the `eth_call` simulations the stub node received.
  private final class SimulationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
      lock.lock(); defer { lock.unlock() }
      return _count
    }
    func increment() {
      lock.lock(); defer { lock.unlock() }
      _count += 1
    }
  }

  /// A manager wired exactly as `PrivyProvider.create(context:)` wires production: the real
  /// transaction builder and a `PrivyWalletProvider` whose reads hit the stub at `host`.
  private static func privyManager(
    host: String,
    signer: FakeSigner
  ) -> RainSdkManager {
    let rpcUrl = "https://\(host)/"
    let configs = [NetworkConfig(chainId: chainId, rpcUrl: rpcUrl)]
    let store = TokenMetadataStore(chainReader: EVMChainReader(networkConfigs: configs))
    let provider = PrivyWalletProvider(
      manager: PrivyManager(source: FakeWalletSource(wallets: [signer])),
      rpcEndpoints: [chainId: rpcUrl],
      tokenStore: store,
      solanaSupport: RainSolanaSupport(networkConfigs: []),
      walletAddressOverride: wallet,
      rpcClient: PrivyRpcClient(session: StubURLProtocol.makeSession())
    )
    return RainSdkManager(
      walletProvider: provider,
      networkConfigs: configs,
      transactionBuilder: TransactionBuilderService(
        networkConfigs: configs,
        rpcClient: JsonRpcClient(session: StubURLProtocol.makeSession())
      ),
      tokenStore: store,
      providerId: .privy,
      capabilities: [],
      authPullChainIds: [chainId],
      authPullTokenAddresses: [chainId: usdc]
    )
  }

  @Test("an unlimited approval reaches Privy with the golden calldata after simulating")
  func unlimitedApprovalRoutesGoldenCalldata() async throws {
    let host = "approval-unlimited.rpc"
    let simulations = SimulationCounter()
    StubURLProtocol.setHandler(host: host) { body in
      if let admin = Self.adminAnswer(body) { return admin }
      guard body["method"] as? String == "eth_call" else {
        return RpcStub.error(code: -32601, message: "unexpected method")
      }
      simulations.increment()
      return RpcStub.result("0x")
    }

    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xAPPROVEHASH"))
    let manager = Self.privyManager(host: host, signer: signer)

    let result = try await manager.approveTokenAllowance(
      chainId: Self.chainId,
      contractAddress: Self.usdc,
      spender: Self.spender
    )

    #expect(result.transactionHash == "0xAPPROVEHASH")
    #expect(signer.events == ["switch:\(Self.chainId)", "request:eth_sendTransaction"])
    #expect(simulations.count == 1) // Privy's preflight was not skipped

    let broadcast = try #require(signer.requestParams.first?.first)
    #expect(broadcast.contains(Self.usdc)) // the approval targets the token contract
    #expect(broadcast.contains(
      "0x095ea7b3" + Self.paddedSpender
        + "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    ))
  }

  @Test("a capped approval scales by the registry's USDC decimals into the golden calldata")
  func cappedApprovalScalesThroughRegistry() async throws {
    let host = "approval-capped.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      if let admin = Self.adminAnswer(body) { return admin }
      return body["method"] as? String == "eth_call"
        ? RpcStub.result("0x")
        : RpcStub.error(code: -32601, message: "unexpected method")
    }

    let signer = FakeSigner(address: Self.wallet, requestResult: .success("0xCAPPEDHASH"))
    let manager = Self.privyManager(host: host, signer: signer)

    let result = try await manager.approveTokenAllowance(
      chainId: Self.chainId,
      contractAddress: Self.usdc,
      spender: Self.spender,
      amount: 250
    )

    #expect(result.transactionHash == "0xCAPPEDHASH")
    // 250 USDC at the registry's 6 decimals = 250_000_000 base units — no decimals parameter,
    // no on-chain read, no 18-decimal guess.
    let broadcast = try #require(signer.requestParams.first?.first)
    #expect(broadcast.contains(
      "0x095ea7b3" + Self.paddedSpender
        + "000000000000000000000000000000000000000000000000000000000ee6b280"
    ))
  }

  @Test("a failed simulation surfaces typed through the manager without broadcasting")
  func simulationFailureIsTypedAndBlocksBroadcast() async throws {
    let host = "approval-sim-fail.rpc"
    StubURLProtocol.setHandler(host: host) { body in
      Self.adminAnswer(body) ?? RpcStub.error(code: 3, message: "execution reverted")
    }

    let signer = FakeSigner(address: Self.wallet)
    let manager = Self.privyManager(host: host, signer: signer)

    await #expect(throws: RainError.transactionSimulationFailed(
      underlying: NSError(domain: "", code: 0)
    )) {
      _ = try await manager.approveTokenAllowance(
        chainId: Self.chainId,
        contractAddress: Self.usdc,
        spender: Self.spender
      )
    }
    #expect(signer.events.isEmpty) // nothing reached the signer
  }
}
