import Foundation
import PortalSwift
import RainCore

// MARK: - Portal → Rain model mappers (kept in the Portal module so RainCore stays vendor-free).

extension RainTransaction {
  /// Maps Portal's `FetchedTransaction` onto the vendor-agnostic `RainTransaction`.
  ///
  /// Enrichment is resolved by the caller and passed in, so every field is known before the row is
  /// built. `decimals` is `nil` when neither Portal nor the on-chain read could supply it — the
  /// amount is then left unscaled rather than fabricated at a default precision.
  static func make(
    _ tx: FetchedTransaction,
    tokenInfo: TokenInfo?,
    nativeSymbol: String?
  ) -> RainTransaction {
    let contractAddress = tx.rawContract?.address
    let decimals = tx.rawContract?.decimal.flatMap { Int($0) } ?? tokenInfo?.decimals

    // Portal reports `value` as a Double; round-trip through its printed form so e.g. 0.1 becomes
    // exactly Decimal("0.1") rather than the full binary float error.
    var value = tx.value.flatMap { AmountHelpers.strictDecimal(from: String($0)) }
    if value == nil, let raw = tx.rawContract?.value, let decimals {
      value = EthereumConverter.parseHexToDecimal(raw, decimals: decimals)
    }

    let asset = tx.asset?.isEmpty == false
      ? tx.asset
      : (contractAddress == nil ? nativeSymbol : tokenInfo?.symbol)

    return RainTransaction(
      hash: tx.hash,
      uniqueId: tx.uniqueId,
      blockNumber: tx.blockNum,
      timestamp: (tx.metadata?.blockTimestamp).map(normalizedZuluTimestamp),
      from: tx.from,
      to: tx.to,
      value: value,
      asset: asset,
      tokenAddress: contractAddress,
      rawValue: tx.rawContract?.value,
      decimals: decimals,
      category: RainTransactionCategory(rawValue: tx.category),
      chainId: tx.chainId
    )
  }
}

/// Second-precision UTC Zulu ISO-8601 ("2026-07-26T12:34:56Z"); unparseable input passes through.
func normalizedZuluTimestamp(_ raw: String) -> String {
  let withFraction = ISO8601DateFormatter()
  withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  guard let date = withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
    return raw
  }
  return ISO8601DateFormatter().string(from: date)
}

extension RainTransactionOrder {
  /// Maps to Portal's `TransactionOrder`.
  var toPortalOrder: TransactionOrder {
    switch self {
    case .ASC: return .ASC
    case .DESC: return .DESC
    }
  }
}
