import Foundation

extension String {
  static let empty: String = ""
  
  func isValidHTTPURL() -> Bool {
    guard
      !self.isEmpty
    else {
      return false
    }
    
    guard
      let components = URLComponents(string: self)
    else {
      return false
    }
    
    guard let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
          !host.isEmpty else { return false }
    let scheme = components.scheme?.lowercased()
    return scheme == "https"
      || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
  }
  
  public var asDouble: Double? {
    Double(self)
  }

  /// Returns the string with a leading `"0x"` or `"0X"` prefix removed.
  @_spi(RainAdapter) public var strippingHexPrefix: String {
    (hasPrefix("0x") || hasPrefix("0X")) ? String(dropFirst(2)) : self
  }

  /// Lightweight syntactic check for a 20-byte Ethereum address: `0x`-optional,
  /// exactly 40 hex characters. Does not validate the checksum.
  var isValidEthereumAddress: Bool {
    let cleaned = strippingHexPrefix
    guard cleaned.count == 40 else { return false }
    return cleaned.allSatisfy(\.isHexDigit)
  }

  /// True for the zero address in any casing, with or without a `0x` prefix.
  var isZeroAddress: Bool {
    let cleaned = strippingHexPrefix
    return !cleaned.isEmpty && cleaned.allSatisfy { $0 == "0" }
  }
}
