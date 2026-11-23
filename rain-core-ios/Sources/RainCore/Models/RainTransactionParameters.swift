//
//  RainTransactionParameters.swift
//  RainSDK
//

import Foundation

/// Rain-owned EVM transaction params (string-typed wire format) returned by
/// `buildTransactionParameters`.
public struct RainTransactionParameters: Sendable, Equatable {
  public let from: String
  public let to: String
  /// Wei value as a hex string (e.g. `"0x0"`).
  public let value: String
  public let data: String

  public init(from: String, to: String, value: String, data: String) {
    self.from = from
    self.to = to
    self.value = value
    self.data = data
  }
}
