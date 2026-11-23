import Foundation
@testable import RainCore

/// Stub for manager-contract tests on the Solana routes. Records what the manager hands the
/// adapter, so tests can pin the `decimals` the port receives without composing a transaction.
final class StubSolanaWalletProvider: WalletProvider, RainSolanaTransfersProvider, @unchecked Sendable {
  var addressToReturn: String = TestFixtures.walletAddress
  var solanaAddressToReturn: String = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  var signatureToReturn: String = String(repeating: "1", count: 88)

  struct SPLTokenCall {
    let chainId: Int
    let mintAddress: String
    let toAddress: String
    let amount: Decimal
    let decimals: Int
  }

  private(set) var splTokenCalls: [SPLTokenCall] = []
  private(set) var nativeCalls: [(chainId: Int, toAddress: String, amount: Decimal)] = []
  private(set) var signAndSendCalls: [(chainId: Int, unsigned: UnsignedSolanaTransfer)] = []

  // MARK: - RainSolanaTransfersProvider

  func sendSolanaNative(chainId: Int, to toAddress: String, amount: Decimal) async throws -> String {
    nativeCalls.append((chainId, toAddress, amount))
    return signatureToReturn
  }

  func sendSolanaSPLToken(
    chainId: Int,
    mintAddress: String,
    to toAddress: String,
    amount: Decimal,
    decimals: Int
  ) async throws -> String {
    splTokenCalls.append(
      SPLTokenCall(
        chainId: chainId, mintAddress: mintAddress, toAddress: toAddress,
        amount: amount, decimals: decimals
      )
    )
    return signatureToReturn
  }

  func signAndSendSolanaTransaction(
    chainId: Int,
    unsigned: UnsignedSolanaTransfer
  ) async throws -> String {
    signAndSendCalls.append((chainId, unsigned))
    return signatureToReturn
  }

  // MARK: - WalletProvider

  func address() async throws -> String { addressToReturn }

  func getAddress(chainId: Int) async throws -> String {
    SolanaChains.isSolana(chainId) ? solanaAddressToReturn : addressToReturn
  }

  func sendTransaction(chainId: Int, params: WalletTransactionParams) async throws -> String {
    signatureToReturn
  }

  func getBalance(chainId: Int, token: Token) async throws -> Balance {
    Balance(token: token, chainId: chainId, rawAmount: 0, decimals: 9)
  }

  func getBalances(chainId: Int) async throws -> [Balance] { [] }

  func getTransactions(
    chainId: Int,
    limit: Int?,
    offset: Int?,
    order: RainTransactionOrder?
  ) async throws -> [RainTransaction] { [] }
}
