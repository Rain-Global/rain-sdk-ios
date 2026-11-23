import Foundation

public enum Constants {
  /// ERC-20 token defaults
  public enum ERC20 {
    /// Default number of decimal places for ERC-20 tokens (e.g. USDC uses 6, most tokens use 18)
    public static let defaultDecimals = 18
  }

  /// Contract ABI JSON names
  /// Used to identify contract ABIs for encoding/decoding operations
  enum ContractABI {
    /// Main contract ABI JSON name
    static let contractJsonABI = "contractJsonABI"

    /// Collateral contract ABI JSON name
    static let collateralJsonABI = "collateralJsonABI"
  }
}
