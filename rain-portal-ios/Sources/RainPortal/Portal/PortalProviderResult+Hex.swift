import Foundation
import PortalSwift
import RainCore

extension PortalProviderResult {
  /// Extracts a hex string from this Portal RPC result.
  ///
  /// Handles two shapes Portal can return:
  ///   - `result` is a raw `String` (e.g. some RPC methods return the hex directly)
  ///   - `result` is a `PortalProviderRpcResponse` whose nested `.result` holds the hex string
  ///
  /// Falls back to `"0x0"` when the payload is missing or malformed, via the shared
  /// `EthereumConverter.normalizedHexString` so the validation logic stays in one place.
  var hexString: String {
    let raw: String?
    switch result {
    case let str as String:
      raw = str
    case let rpcResponse as PortalProviderRpcResponse:
      raw = rpcResponse.result
    default:
      raw = nil
    }
    return EthereumConverter.normalizedHexString(raw)
  }
}
