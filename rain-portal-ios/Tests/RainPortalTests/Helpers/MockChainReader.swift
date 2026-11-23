import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

/// Test double for `ChainReader`. Records every call and returns canned values.
/// Used to assert that the Turnkey adapter delegates to the chain reader for
/// non-Turnkey chains while still using Turnkey's API for the allowlisted ones.
final class MockChainReader: ChainReader, @unchecked Sendable {
  struct BalancesCall: Equatable {
    let chainId: Int
    let walletAddress: String
    let tokenAddresses: [String]
  }

  struct ERC20Call: Equatable {
    let chainId: Int
    let tokenAddress: String
    let walletAddress: String
    let decimals: Int?
  }

  struct NativeCall: Equatable {
    let chainId: Int
    let walletAddress: String
  }

  struct SingleBalanceCall: Equatable {
    let chainId: Int
    let walletAddress: String
    let token: Token
  }

  struct MetadataCall: Equatable {
    let chainId: Int
    let tokenAddress: String
  }

  struct AllowanceCall: Equatable {
    let chainId: Int
    let tokenAddress: String
    let owner: String
    let spender: String
    let atBlock: String
  }

  struct ReceiptCall: Equatable {
    let chainId: Int
    let transactionHash: String
  }

  var stubbedBalances: [Balance] = []
  var stubbedSingleBalance: Balance? = nil
  var stubbedNative: Decimal = 0
  var stubbedErc20: Decimal = 0
  var stubbedDecimals: Int = 18
  var stubbedSymbol: String? = nil
  var stubbedName: String? = nil
  var stubbedAllowance: BigUInt = 0
  /// When set, the allowance read throws it.
  var stubbedAllowanceError: Error? = nil
  /// Allowance per block tag; a read whose `atBlock` is absent here falls back to
  /// ``stubbedAllowance``.
  var stubbedAllowanceByBlock: [String: BigUInt] = [:]
  var stubbedReceiptStatus: Bool? = true
  /// Consumed one entry per receipt read before falling back to ``stubbedReceiptStatus``.
  var stubbedReceiptStatuses: [Bool?] = []
  /// Block the mined receipt reports — the tag a confirmation read is expected to pin to.
  var stubbedReceiptBlockNumber: String = "0x10"

  private(set) var balancesCalls: [BalancesCall] = []
  private(set) var getBalanceCalls: [SingleBalanceCall] = []
  private(set) var nativeCalls: [NativeCall] = []
  private(set) var erc20Calls: [ERC20Call] = []
  private(set) var decimalsCalls: [MetadataCall] = []
  private(set) var symbolCalls: [MetadataCall] = []
  private(set) var nameCalls: [MetadataCall] = []
  private(set) var allowanceCalls: [AllowanceCall] = []
  private(set) var receiptCalls: [ReceiptCall] = []

  func getNativeBalance(chainId: Int, walletAddress: String) async throws -> Decimal {
    nativeCalls.append(NativeCall(chainId: chainId, walletAddress: walletAddress))
    return stubbedNative
  }

  func getERC20Balance(
    chainId: Int,
    tokenAddress: String,
    walletAddress: String,
    decimals: Int?
  ) async throws -> Decimal {
    erc20Calls.append(
      ERC20Call(
        chainId: chainId,
        tokenAddress: tokenAddress,
        walletAddress: walletAddress,
        decimals: decimals
      )
    )
    return stubbedErc20
  }

  func getBalances(
    chainId: Int,
    walletAddress: String,
    tokens: [TokenInfo]
  ) async throws -> [Balance] {
    balancesCalls.append(
      BalancesCall(
        chainId: chainId,
        walletAddress: walletAddress,
        tokenAddresses: tokens.map(\.address)
      )
    )
    return stubbedBalances
  }

  func getBalance(
    chainId: Int,
    walletAddress: String,
    token: Token,
    tokenInfo: TokenInfo?
  ) async throws -> Balance {
    getBalanceCalls.append(
      SingleBalanceCall(chainId: chainId, walletAddress: walletAddress, token: token)
    )
    if let stubbedSingleBalance {
      return stubbedSingleBalance
    }
    return Balance(
      token: token,
      chainId: chainId,
      rawAmount: 0,
      decimals: tokenInfo?.decimals ?? stubbedDecimals,
      symbol: tokenInfo?.symbol ?? stubbedSymbol,
      name: tokenInfo?.name
    )
  }

  func getDecimals(chainId: Int, tokenAddress: String) async throws -> Int {
    decimalsCalls.append(MetadataCall(chainId: chainId, tokenAddress: tokenAddress))
    return stubbedDecimals
  }

  func getSymbol(chainId: Int, tokenAddress: String) async throws -> String? {
    symbolCalls.append(MetadataCall(chainId: chainId, tokenAddress: tokenAddress))
    return stubbedSymbol
  }

  func getName(chainId: Int, tokenAddress: String) async throws -> String? {
    nameCalls.append(MetadataCall(chainId: chainId, tokenAddress: tokenAddress))
    return stubbedName
  }

  func getERC20Allowance(
    chainId: Int,
    tokenAddress: String,
    owner: String,
    spender: String,
    atBlock: String
  ) async throws -> BigUInt {
    allowanceCalls.append(
      AllowanceCall(
        chainId: chainId,
        tokenAddress: tokenAddress,
        owner: owner,
        spender: spender,
        atBlock: atBlock
      )
    )
    if let stubbedAllowanceError { throw stubbedAllowanceError }
    return stubbedAllowanceByBlock[atBlock] ?? stubbedAllowance
  }

  func getTransactionReceipt(
    chainId: Int,
    transactionHash: String
  ) async throws -> MinedReceipt? {
    receiptCalls.append(ReceiptCall(chainId: chainId, transactionHash: transactionHash))
    let status = stubbedReceiptStatuses.isEmpty
      ? stubbedReceiptStatus
      : stubbedReceiptStatuses.removeFirst()
    return status.map { MinedReceipt(succeeded: $0, blockNumber: stubbedReceiptBlockNumber) }
  }
}
