import Foundation
import Web3
@testable import RainCore

/// Provider-agnostic stub for manager-contract tests. Returns configured values and
/// records calls — use when a test only needs to prove the manager routes to the
/// provider and returns the provider's result, without invoking Portal- or Turnkey-specific behavior.
class StubWalletProvider: WalletProvider, @unchecked Sendable {
  var addressToReturn: String = TestFixtures.walletAddress
  var balanceToReturn: Balance?
  var balancesToReturn: [Balance] = []
  var transactionsToReturn: [RainTransaction] = []
  var sendTransactionHashToReturn: String = "0x" + String(repeating: "0", count: 64)
  /// When set, `sendTransaction` throws it — drives user-rejection and revert paths.
  var sendTransactionError: Error?
  /// Chains this stub refuses to broadcast on — `requireSendSupport` throws `chainNotSupported`.
  var unsupportedSendChainIds: Set<Int> = []
  /// Chains this stub reports as fee-sponsored.
  var sponsoredChainIds: Set<Int> = []
  private(set) var requireSendSupportCalls: [Int] = []

  /// Per-chain overrides for `getBalances`. When a chainId has an entry, it takes
  /// precedence over `balancesToReturn`.
  var balancesByChainId: [Int: [Balance]] = [:]
  /// Per-chain errors. When a chainId has an entry, both balance methods throw it.
  var errorsByChainId: [Int: Error] = [:]

  private(set) var sendTransactionCalls: [(chainId: Int, params: WalletTransactionParams)] = []
  private(set) var getBalanceCalls: [(chainId: Int, token: Token)] = []
  private(set) var getBalancesCalls: [Int] = []
  private(set) var getTransactionsCalls: [(chainId: Int, limit: Int?, offset: Int?, order: RainTransactionOrder?)] = []

  func address() async throws -> String { addressToReturn }

  func requireSendSupport(chainId: Int) throws {
    requireSendSupportCalls.append(chainId)
    if unsupportedSendChainIds.contains(chainId) {
      throw RainError.chainNotSupported(chainId: chainId, details: "stub cannot broadcast here")
    }
  }

  func sponsorsFees(chainId: Int) -> Bool { sponsoredChainIds.contains(chainId) }

  func sendTransaction(chainId: Int, params: WalletTransactionParams) async throws -> String {
    sendTransactionCalls.append((chainId, params))
    if let sendTransactionError { throw sendTransactionError }
    return sendTransactionHashToReturn
  }

  func getBalance(chainId: Int, token: Token) async throws -> Balance {
    getBalanceCalls.append((chainId, token))
    if let err = errorsByChainId[chainId] { throw err }
    return balanceToReturn ?? Balance(token: token, chainId: chainId, rawAmount: 0, decimals: 18)
  }

  func getBalances(chainId: Int) async throws -> [Balance] {
    getBalancesCalls.append(chainId)
    if let err = errorsByChainId[chainId] { throw err }
    return balancesByChainId[chainId] ?? balancesToReturn
  }

  func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] {
    getTransactionsCalls.append((chainId, limit, offset, order))
    return transactionsToReturn
  }
}

/// EIP-712 signing so the stub can carry an EVM withdrawal end to end (the manager requires a
/// typed-data signer for that path). Returns a well-formed 65-byte signature.
extension StubWalletProvider: RainTypedDataSignerProvider {
  func signTypedData(chainId: Int, walletAddress: String, typedData: String) async throws -> String {
    TestFixtures.validSignatureHex
  }
}

/// A stub that can also quote fees. Kept separate so the base stub stays a provider that CANNOT
/// estimate (tests pin that path). Quotes `estimatedFeeToReturn` — the "chain" cost, regardless
/// of sponsorship — and records the chain asked about.
final class FeeEstimatingStubWalletProvider: StubWalletProvider, RainTransactionFeeEstimatingProvider {
  var estimatedFeeToReturn: Decimal = 0.00042
  private(set) var estimateTransactionFeeCalls: [Int] = []

  func estimateTransactionFee(
    chainId: Int, walletAddress: String, params: WalletTransactionParams
  ) async throws -> Decimal {
    estimateTransactionFeeCalls.append(chainId)
    return estimatedFeeToReturn
  }
}
