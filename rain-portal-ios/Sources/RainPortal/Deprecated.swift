import Foundation
import PortalSwift
import RainCore

public extension RainSdk {
  /// Deprecated. Use ``RainSdk/buildTransactionParameters(walletAddress:contractAddress:transactionData:)``
  /// which returns Rain-owned `RainTransactionParameters`. This shim adapts to Portal's
  /// `ETHTransactionParam` and lives in the `RainPortal` module.
  @available(*, deprecated, message: "Renamed to buildTransactionParameters, which returns Rain-owned RainTransactionParameters. This shim adapts to Portal's ETHTransactionParam.")
  func composeTransactionParameters(
    walletAddress: String,
    contractAddress: String,
    transactionData: String
  ) -> ETHTransactionParam {
    let p = buildTransactionParameters(
      walletAddress: walletAddress,
      contractAddress: contractAddress,
      transactionData: transactionData
    )
    return ETHTransactionParam(from: p.from, to: p.to, value: p.value, data: p.data)
  }
}
