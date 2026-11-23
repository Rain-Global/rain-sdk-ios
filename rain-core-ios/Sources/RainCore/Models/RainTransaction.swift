//
//  RainTransaction.swift
//  RainSDK
//

import Foundation

/// Transaction category. An extensible constant rather than a closed enum: Portal passes its
/// indexer's vocabulary straight through, and an unrecognised value must not be dropped.
public struct RainTransactionCategory: RawRepresentable, Sendable, Hashable {
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }

  /// A plain value transfer between externally-owned accounts.
  public static let external = RainTransactionCategory(rawValue: "external")
  /// A fungible-token transfer whose standard the provider does not name (Solana SPL).
  public static let token = RainTransactionCategory(rawValue: "token")
  public static let erc20 = RainTransactionCategory(rawValue: "erc20")
  public static let erc721 = RainTransactionCategory(rawValue: "erc721")
  public static let erc1155 = RainTransactionCategory(rawValue: "erc1155")
  /// A transfer made by a contract while executing another transaction.
  public static let contractInternal = RainTransactionCategory(rawValue: "internal")
}

/// A wallet transaction returned by `getTransactions`. Vendor-agnostic; each provider adapter maps
/// its own history source onto this in its own module.
public struct RainTransaction: Sendable, Equatable {

  /// Indexer-supplied detail. Populated only by providers whose history source carries it, plus
  /// the two Solana token-account fields. `nil` for every other row.
  public struct Metadata: Sendable, Equatable {
    /// CAIP-2 identifier of the chain the transaction executed on (e.g. `eip155:1`).
    public var caip2: String?
    /// Indexer-reported status (e.g. `broadcasted`, `confirmed`, `finalized`, `failed`).
    public var status: String?
    /// Whether the transaction's gas was sponsored.
    public var sponsored: Bool?
    /// Privy's internal id, when the row came from Privy's indexer.
    public var privyTransactionId: String?
    /// ERC-4337 user-operation hash, when submitted as a user operation.
    public var userOperationHash: String?
    /// Transfer direction (e.g. `transferSent`, `transferReceived`).
    public var type: String?
    /// Human-readable value renderings keyed by unit, as supplied by the indexer.
    public var displayValues: [String: String]?
    /// SPL only: the sender's token account (not the wallet).
    public var sourceTokenAccount: String?
    /// SPL only: the recipient's token account — `to` holds the wallet where it could be resolved.
    public var destinationTokenAccount: String?

    public init(
      caip2: String? = nil,
      status: String? = nil,
      sponsored: Bool? = nil,
      privyTransactionId: String? = nil,
      userOperationHash: String? = nil,
      type: String? = nil,
      displayValues: [String: String]? = nil,
      sourceTokenAccount: String? = nil,
      destinationTokenAccount: String? = nil
    ) {
      self.caip2 = caip2
      self.status = status
      self.sponsored = sponsored
      self.privyTransactionId = privyTransactionId
      self.userOperationHash = userOperationHash
      self.type = type
      self.displayValues = displayValues
      self.sourceTokenAccount = sourceTokenAccount
      self.destinationTokenAccount = destinationTokenAccount
    }
  }

  /// Transaction hash (EVM) or signature (Solana). May be a provider-internal activity id when the
  /// real hash is not known yet, and may be empty for a row carrying neither.
  public let hash: String
  /// Provider-stable row identifier, when the history source has one. May be absent or blank —
  /// do not use it as a list key.
  public let uniqueId: String?
  /// Block the transaction was included in. Only providers with an indexed history source fill this.
  public let blockNumber: String?
  /// ISO-8601 timestamp of the block, or of the provider activity when there is no block yet.
  public let timestamp: String?
  /// Sender address.
  public let from: String
  /// Recipient address. For SPL rows this is the recipient's *wallet* where it could be resolved
  /// (see ``Metadata/destinationTokenAccount``).
  public let to: String?
  /// Amount in human-readable units (e.g. `1.5` for 1.5 ETH). `nil` when decimals could not be
  /// resolved — `rawValue` is still populated in that case.
  ///
  /// `Decimal` holds 38 significant digits. Portal-sourced rows are derived from the vendor's
  /// `Double`; prefer `rawValue` + `decimals` when exactness matters.
  public let value: Decimal?
  /// Asset symbol (e.g. `ETH`, `SOL`, `USDC`), when the provider can resolve one.
  public let asset: String?
  /// Contract address (EVM) or mint (Solana). `nil` for a native transfer.
  public let tokenAddress: String?
  /// Amount in the token's smallest unit, as an unscaled decimal string.
  public let rawValue: String?
  /// Decimals used to scale `rawValue` into `value`.
  public let decimals: Int?
  /// Transaction category. See ``RainTransactionCategory``.
  public let category: RainTransactionCategory?
  /// Chain the transaction executed on.
  public let chainId: Int
  /// Indexer / Solana detail; see ``Metadata``.
  public let metadata: Metadata?

  public init(
    hash: String,
    uniqueId: String? = nil,
    blockNumber: String? = nil,
    timestamp: String? = nil,
    from: String,
    to: String? = nil,
    value: Decimal? = nil,
    asset: String? = nil,
    tokenAddress: String? = nil,
    rawValue: String? = nil,
    decimals: Int? = nil,
    category: RainTransactionCategory? = nil,
    chainId: Int,
    metadata: Metadata? = nil
  ) {
    self.hash = hash
    self.uniqueId = uniqueId
    self.blockNumber = blockNumber
    self.timestamp = timestamp
    self.from = from
    self.to = to
    self.value = value
    self.asset = asset
    self.tokenAddress = tokenAddress
    self.rawValue = rawValue
    self.decimals = decimals
    self.category = category
    self.chainId = chainId
    self.metadata = metadata
  }
}
