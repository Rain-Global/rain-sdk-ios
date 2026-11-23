import Foundation
import Web3

/// Tells a payer's lamport shortfall apart from a program refusal, in a dry run and in a
/// provider's failed status alike.
@_spi(RainAdapter) public enum SolanaLamportShortfall {
  /// The System Program's own line (an `ic_msg`, so no `Program log:` prefix); a program's log
  /// never has this shape. Emitted when a created account's payer cannot fund it, where the
  /// transaction error is only `Custom(1)`.
  private static let systemTransfer = try! NSRegularExpression(
    pattern: #"^Transfer: insufficient lamports (\d+), need (\d+)$"#
  )

  /// `insufficientFunds` when the runtime named the shortfall (`InsufficientFundsForFee` /
  /// `InsufficientFundsForRent`, amounts unknown) or the System Program logged it (amounts in
  /// SOL); `nil` otherwise.
  public static func classify(transactionError: String?, logs: [String]) -> RainError? {
    let error = transactionError ?? ""
    if error.contains("InsufficientFundsForFee") || error.contains("InsufficientFundsForRent") {
      return .insufficientFunds(required: "unknown", available: "unknown")
    }
    for line in logs {
      let range = NSRange(line.startIndex..., in: line)
      guard let match = systemTransfer.firstMatch(in: line, range: range),
            let heldRange = Range(match.range(at: 1), in: line),
            let neededRange = Range(match.range(at: 2), in: line),
            let held = BigUInt(String(line[heldRange])),
            let needed = BigUInt(String(line[neededRange]))
      else { continue }
      return .insufficientFunds(
        required: SolanaConverter.lamportsToSol(needed).description,
        available: SolanaConverter.lamportsToSol(held).description
      )
    }
    return nil
  }
}
