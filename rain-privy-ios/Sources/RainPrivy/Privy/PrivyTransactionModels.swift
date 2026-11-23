import Foundation
import PrivySDK

/// Internal mirrors of PrivySDK's transaction-history models.
///
/// PrivySDK's `TransactionsPage` / `WalletTransaction` have no public initializers, so returning
/// them through ``PrivyEthereumSigner`` would make the seam unconstructible in tests. The live
/// signer maps the vendor structs onto these once, at the seam boundary.
struct PrivyTransactionsPage: Sendable {
  let transactions: [PrivyIndexedTransaction]
  let nextCursor: String?
}

/// One transaction row from Privy's indexer, with enum cases flattened to their wire strings.
struct PrivyIndexedTransaction: Sendable {
  struct Details: Sendable {
    let type: String
    let sender: String
    let recipient: String
    let asset: String
    let rawValue: String
    let rawValueDecimals: Int
    let displayValues: [String: String]
  }

  let caip2: String
  let transactionHash: String?
  let userOperationHash: String?
  let status: String
  /// Unix timestamp in milliseconds.
  let createdAt: Int
  let sponsored: Bool
  let privyTransactionId: String?
  let walletId: String
  let details: Details?
}

extension PrivyTransactionsPage {
  init(page: PrivySDK.TransactionsPage) {
    self.init(
      transactions: page.transactions.map(PrivyIndexedTransaction.init),
      nextCursor: page.nextCursor
    )
  }
}

extension PrivyIndexedTransaction {
  init(transaction: PrivySDK.WalletTransaction) {
    self.init(
      caip2: transaction.caip2,
      transactionHash: transaction.transactionHash,
      userOperationHash: transaction.userOperationHash,
      status: Self.statusValue(transaction.status),
      createdAt: transaction.createdAt,
      sponsored: transaction.sponsored,
      privyTransactionId: transaction.privyTransactionId,
      walletId: transaction.walletId,
      details: transaction.details.map(Details.init)
    )
  }

  private static func statusValue(_ status: PrivySDK.TransactionStatus) -> String {
    switch status {
    case .broadcasted: return "broadcasted"
    case .confirmed: return "confirmed"
    case .executionReverted: return "executionReverted"
    case .failed: return "failed"
    case .replaced: return "replaced"
    case .finalized: return "finalized"
    case .providerError: return "providerError"
    case .pending: return "pending"
    case .unknown(let rawValue): return rawValue
    @unknown default: return "unknown"
    }
  }
}

extension PrivyIndexedTransaction.Details {
  init(details: PrivySDK.TransactionDetails) {
    self.init(
      type: Self.typeValue(details.type),
      sender: details.sender,
      recipient: details.recipient,
      asset: details.asset,
      rawValue: details.rawValue,
      rawValueDecimals: details.rawValueDecimals,
      displayValues: details.displayValues
    )
  }

  private static func typeValue(_ type: PrivySDK.TransactionType) -> String {
    switch type {
    case .transferSent: return "transferSent"
    case .transferReceived: return "transferReceived"
    case .unknown(let rawValue): return rawValue
    @unknown default: return "unknown"
    }
  }
}
