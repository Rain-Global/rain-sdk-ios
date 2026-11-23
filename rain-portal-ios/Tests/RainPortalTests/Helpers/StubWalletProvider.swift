import Foundation
import Web3
@testable import RainCore

/// Provider-agnostic stub for manager-contract tests. Duplicated into the portal test target
/// (test targets can't share code across packages).
final class StubWalletProvider: WalletProvider, @unchecked Sendable {
  var addressToReturn: String = TestFixtures.walletAddress
  var balanceToReturn: Balance?
  var balancesToReturn: [Balance] = []
  var transactionsToReturn: [RainTransaction] = []
  var sendTransactionHashToReturn: String = "0x" + String(repeating: "0", count: 64)

  var balancesByChainId: [Int: [Balance]] = [:]
  var errorsByChainId: [Int: Error] = [:]

  private(set) var sendTransactionCalls: [(chainId: Int, params: WalletTransactionParams)] = []
  private(set) var getBalanceCalls: [(chainId: Int, token: Token)] = []
  private(set) var getBalancesCalls: [Int] = []
  private(set) var getTransactionsCalls: [(chainId: Int, limit: Int?, offset: Int?, order: RainTransactionOrder?)] = []

  func address() async throws -> String { addressToReturn }

  func sendTransaction(chainId: Int, params: WalletTransactionParams) async throws -> String {
    sendTransactionCalls.append((chainId, params))
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
