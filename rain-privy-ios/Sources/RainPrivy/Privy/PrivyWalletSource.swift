import Foundation
import PrivySDK

/// Narrow seam over the Privy SDK — the operations ``PrivyManager`` needs.
protocol PrivyWalletSource: Sendable {
  /// The authenticated user's embedded Ethereum wallets, or `nil` when no user is authenticated
  /// (distinct from `[]`, which means an authenticated user with no wallet yet).
  func embeddedEthereumWallets() async -> [any PrivyEthereumSigner]?

  /// The user's embedded Solana wallets (same `nil` / `[]` distinction). Privy keeps these
  /// separate from Ethereum ones, so a user may have either, both, or neither.
  func embeddedSolanaWallets() async -> [any PrivySolanaAccount]?
}

/// The signing surface of one Privy embedded Ethereum wallet.
protocol PrivyEthereumSigner: Sendable {
  var address: String { get }
  func request(_ request: EthereumRpcRequest) async throws -> String
  func switchChain(chainId: Int, rpcUrl: String?) async
  func getTransactions(_ params: GetTransactionsParams) async throws -> PrivyTransactionsPage
}

/// The signing surface of one Privy embedded Solana wallet.
protocol PrivySolanaAccount: Sendable {
  var address: String { get }

  /// Signs and broadcasts a serialized transaction, returning the Solana signature. Privy owns
  /// the broadcast, so the cluster (CAIP-2 + RPC URL) is passed per call.
  func signAndSendTransaction(
    transaction: Data,
    caip2: String,
    rpcUrl: String
  ) async throws -> String

  /// One page of the Solana account's transaction history from Privy's indexer.
  func getTransactions(_ params: GetTransactionsParams) async throws -> PrivyTransactionsPage
}

/// Production `PrivyWalletSource` backed by the real Privy singleton.
struct LivePrivyWalletSource: PrivyWalletSource {
  let privy: any Privy

  func embeddedEthereumWallets() async -> [any PrivyEthereumSigner]? {
    guard let user = await privy.getUser() else { return nil }
    return user.embeddedEthereumWallets.map(LivePrivyEthereumSigner.init)
  }

  func embeddedSolanaWallets() async -> [any PrivySolanaAccount]? {
    guard let user = await privy.getUser() else { return nil }
    return user.embeddedSolanaWallets.map(LivePrivySolanaAccount.init)
  }
}

/// Production `PrivySolanaAccount` wrapping a real embedded Solana wallet.
struct LivePrivySolanaAccount: PrivySolanaAccount {
  let wallet: any EmbeddedSolanaWallet

  var address: String { wallet.address }

  func signAndSendTransaction(
    transaction: Data,
    caip2: String,
    rpcUrl: String
  ) async throws -> String {
    try await wallet.provider.signAndSendTransaction(
      transaction: transaction,
      cluster: SolanaCluster(caip2: caip2, rpcUrl: rpcUrl),
      options: nil
    )
  }

  func getTransactions(_ params: GetTransactionsParams) async throws -> PrivyTransactionsPage {
    PrivyTransactionsPage(page: try await wallet.getTransactions(params))
  }
}

/// Production `PrivyEthereumSigner` wrapping a real embedded wallet.
struct LivePrivyEthereumSigner: PrivyEthereumSigner {
  let wallet: any EmbeddedEthereumWallet

  var address: String { wallet.address }

  func request(_ request: EthereumRpcRequest) async throws -> String {
    try await wallet.provider.request(request)
  }

  func switchChain(chainId: Int, rpcUrl: String?) async {
    await wallet.provider.switchChain(chainId: chainId, rpcUrl: rpcUrl)
  }

  func getTransactions(_ params: GetTransactionsParams) async throws -> PrivyTransactionsPage {
    PrivyTransactionsPage(page: try await wallet.getTransactions(params))
  }
}
