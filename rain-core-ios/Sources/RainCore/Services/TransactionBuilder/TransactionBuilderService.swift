import Foundation
import Web3
import Web3ContractABI

/// Service for building transaction components
/// Handles EIP-712 message generation, contract interactions, and ABI management
final class TransactionBuilderService: TransactionBuilderProtocol {
  // MARK: - Properties
  
  private let networkConfigs: [NetworkConfig]
  private let networkConfigsByChainId: [Int: NetworkConfig]
  private let rpcClient: JsonRpcClient

  // MARK: - Initialization

  init(networkConfigs: [NetworkConfig], rpcClient: JsonRpcClient = JsonRpcClient()) {
    self.networkConfigs = networkConfigs
    self.rpcClient = rpcClient
    self.networkConfigsByChainId = Dictionary(uniqueKeysWithValues: 
      networkConfigs.map { ($0.chainId, $0) })
  }
  
  // MARK: - Salt Generation
  
  /// Generate random 32-byte salt for EIP-712 domain.
  ///
  /// Uses `SystemRandomNumberGenerator` (CSPRNG-backed on Darwin, cannot fail) rather than
  /// `SecRandomCopyBytes`, whose failure would otherwise leave an all-zero salt.
  func generateSalt() -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
  }
  
  // MARK: - Nonce Retrieval
  
  /// Get latest nonce from contract
  func getLatestNonce(
    proxyAddress: String,
    chainId: Int
  ) async throws -> BigUInt {
    let rpcURL = try getRpcURL(chainId: chainId)
    let proxy = try RainWithdrawAddresses.checksummed(proxyAddress, label: "proxyAddress")

    do {
      guard let contract = try? Web3(rpcURL: rpcURL).eth.Contract(
              json: Data(Self.adminNonceABI.utf8), abiKey: nil, address: EthereumAddress.parse(proxy)
            ),
            let calldata = contract["adminNonce"]?().encodeABI()
      else {
        throw RainError.internalError(details: "Collateral ABI is missing adminNonce")
      }
      let result = try await rpcClient.callForHexResult(
        rpcUrl: rpcURL,
        method: "eth_call",
        params: [["to": proxy, "data": calldata.hex()], "latest"]
      )
      let hex = result.strippingHexPrefix
      guard hex.count >= 64, hex.count % 64 == 0, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
        throw RainError.internalError(details: "adminNonce value not found in contract response")
      }
      return try EthereumConverter.parseHexToBigUIntStrict(String(hex.prefix(64)))
    } catch is CancellationError {
      throw CancellationError()
    } catch RainError.transactionSimulationFailed(let underlying) {
      throw RainError.internalError(details: "adminNonce call to \(proxy) reverted: \(underlying.localizedDescription)")
    } catch RainError.providerError(let underlying) where (underlying as NSError).domain == "eth.rpc" {
      let rpcError = underlying as NSError
      throw RainError.internalError(details: "RPC error [\(rpcError.code)]: \(rpcError.localizedDescription)")
    } catch RainError.providerError(let underlying) where (underlying as NSError).domain == NSCocoaErrorDomain {
      throw RainError.networkError(underlying: underlying)
    } catch let error as RainError {
      throw error
    } catch {
      RainLogger.error("Rain SDK: Error calling contract for nonce - \(error.localizedDescription)")
      throw RainError.from(underlying: error)
    }
  }

  /// Minimal single-function ABIs for the collateral reads. The full collateral ABI contains
  /// `error` and `receive` entries the ABI decoder does not understand (it decodes the whole
  /// file up front), so each read carries only the function it calls — the same approach the
  /// withdrawAsset encoder takes.
  private static let adminNonceABI = """
    [{"inputs":[],"name":"adminNonce","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]
    """
  private static let isAdminABI = """
    [{"inputs":[{"name":"_address","type":"address"}],"name":"isAdmin","outputs":[{"name":"","type":"bool"}],"stateMutability":"view","type":"function"}]
    """

  // MARK: - Admin Check

  func isCollateralAdmin(
    proxyAddress: String,
    walletAddress: String,
    chainId: Int
  ) async throws -> CollateralAdminCheck {
    do {
      let rpcURL = try getRpcURL(chainId: chainId)
      let proxy = try RainWithdrawAddresses.checksummed(proxyAddress, label: "proxyAddress")
      let wallet = try RainWithdrawAddresses.checksummed(walletAddress, label: "walletAddress")
      guard let walletAddress = EthereumAddress.parse(wallet),
            let contract = try? Web3(rpcURL: rpcURL).eth.Contract(
              json: Data(Self.isAdminABI.utf8), abiKey: nil, address: EthereumAddress.parse(proxy)
            ),
            let calldata = contract["isAdmin"]?(walletAddress).encodeABI()
      else {
        throw RainError.internalError(details: "Could not encode isAdmin(\(wallet))")
      }

      let response = try await rpcClient.call(
        rpcUrl: rpcURL,
        method: "eth_call",
        params: [["to": proxy, "data": calldata.hex()], "latest"]
      )
      return try Self.adminCheck(fromCallResult: response["result"] as? String, proxy: proxy)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RainError {
      RainLogger.debug("Rain SDK: isAdmin read on \(proxyAddress) ended with \(error)")
      // A revert means the address exposes no `isAdmin`, so it is not a collateral contract.
      if case .transactionSimulationFailed = error { return .notCollateral }
      if case .providerError(let underlying) = error, (underlying as NSError).domain == "eth.rpc" {
        let rpcError = underlying as NSError
        return .failed(.internalError(details: "RPC error [\(rpcError.code)]: \(rpcError.localizedDescription)"))
      }
      if case .providerError(let underlying) = error, (underlying as NSError).domain == NSCocoaErrorDomain {
        return .failed(.networkError(underlying: underlying))
      }
      return .failed(error)
    } catch {
      return .failed(RainError.from(underlying: error))
    }
  }

  /// Decodes an `isAdmin` answer: whole 32-byte words of hex only. No data, or a first word other
  /// than 0 or 1, is not a collateral contract; anything else does not decode (`internalError`).
  static func adminCheck(fromCallResult result: String?, proxy: String) throws -> CollateralAdminCheck {
    guard let hex = result?.strippingHexPrefix,
          hex.count % 64 == 0, hex.allSatisfy({ $0.isASCII && $0.isHexDigit })
    else {
      throw RainError.internalError(details: "isAdmin call to \(proxy) returned no decodable value")
    }
    guard !hex.isEmpty, let word = BigUInt(String(hex.prefix(64)), radix: 16) else { return .notCollateral }
    switch word {
    case 1: return .admin
    case 0: return .notAdmin
    default: return .notCollateral
    }
  }

  // MARK: - EIP-712 Message Building

  /// Build EIP-712 message structure
  func buildEIP712Message(
    chainId: Int,
    collateralProxyAddress: String,
    walletAddress: String,
    tokenAddress: String,
    amount: BigUInt,
    recipientAddress: String,
    nonce: BigUInt,
    salt: String
  ) throws -> String {
    // Build EIP-712 domain
    let domain: [String: Any] = [
      "name": "Collateral",
      "version": "2",
      "chainId": chainId,
      "verifyingContract": collateralProxyAddress,
      "salt": salt
    ]
    
    // Build EIP-712 types
    let types: [String: Any] = [
      "EIP712Domain": [
        ["name": "name", "type": "string"],
        ["name": "version", "type": "string"],
        ["name": "chainId", "type": "uint256"],
        ["name": "verifyingContract", "type": "address"],
        ["name": "salt", "type": "bytes32"]
      ],
      "Withdraw": [
        ["name": "user", "type": "address"],
        ["name": "asset", "type": "address"],
        ["name": "amount", "type": "uint256"],
        ["name": "recipient", "type": "address"],
        ["name": "nonce", "type": "uint256"]
      ]
    ]
    
    // Build message
    let message: [String: Any] = [
      "user": walletAddress,
      "asset": tokenAddress,
      "amount": amount.description,
      "recipient": recipientAddress,
      "nonce": nonce.description
    ]
    
    // Build complete EIP-712 message
    let messageToSign: [String: Any] = [
      "types": types,
      "domain": domain,
      "primaryType": "Withdraw",
      "message": message
    ]
    
    // Serialize to JSON
    let jsonData = try JSONSerialization.data(
      withJSONObject: messageToSign,
      options: [.sortedKeys]
    )
    
    guard let messageString = String(data: jsonData, encoding: .utf8) else {
      RainLogger.error("Rain SDK: Error building EIP-712 message. Could not build message string")
      throw RainError.internalError(
        details: "Failed to serialize EIP-712 message to JSON"
      )
    }
    
    RainLogger.debug("Rain SDK: Built EIP-712 message for chain \(chainId)")
    return messageString
  }
  
  /// Build withdraw transaction data.
  ///
  /// Pure ABI encoding — no RPC, so it needs no chain id and cannot fail on the network. Encodes
  /// against a minimal single-function ABI (only `withdrawAsset`) rather than the full contract
  /// ABI, so the parser touches nothing it does not need.
  func buildErc20TransactionForWithdrawAsset(
    ethereumContractAddress: EthereumAddress,
    withdrawAssetParameter: WithdrawAssetParameter
  ) throws -> String {
    // bytes32 fields must be exactly 32 bytes or the ABI encoder fails the encode (returns nil).
    // Surface a precise error instead of the opaque "Could not encode" when they aren't.
    guard withdrawAssetParameter.executorSalt.count == 32,
          withdrawAssetParameter.walletSalt.count == 32 else {
      RainLogger.error("Rain SDK: Error building withdrawal. bytes32 salt is not 32 bytes (executor=\(withdrawAssetParameter.executorSalt.count), wallet=\(withdrawAssetParameter.walletSalt.count))")
      throw RainError.internalError(
        details: "Withdrawal salt must be 32 bytes (executor=\(withdrawAssetParameter.executorSalt.count), wallet=\(withdrawAssetParameter.walletSalt.count))"
      )
    }

    return WithdrawAssetCalldata.encode(withdrawAssetParameter)
  }


  /// ABI-encodes a `balanceOf(address)` call. `chainId` is still validated against the
  /// configured networks so a misconfigured chain fails here, like before.
  func encodeBalanceOfCall(walletAddress: String, chainId: Int) async throws -> String {
    let rpcURL = try getRpcURL(chainId: chainId)

    guard let address = EthereumAddress.parse(walletAddress) else {
      RainLogger.error("Rain SDK: encodeBalanceOfCall — invalid wallet address or RPC URL for chain \(chainId)")
      throw RainError.internalError(details: "Invalid wallet address or RPC URL for chain ID \(chainId)")
    }

    let web3 = Web3(rpcURL: rpcURL)
    let contract = web3.eth.Contract(type: GenericERC20Contract.self, address: nil)

    guard let encoded = contract.balanceOf(address: address).encodeABI() else {
      RainLogger.error("Rain SDK: encodeBalanceOfCall — ABI encoding failed")
      throw RainError.internalError(details: "Could not encode balanceOf call")
    }

    return encoded.hex()
  }

  /// Builds ERC-20 transfer(to, amount) transaction data.
  /// Uses the ERC-20 contract interface to encode the transfer call and returns the transaction data (calldata) only.
  func buildERC20TransferData(
    chainId: Int,
    contractAddress: String,
    walletAddress: String,
    toAddress: String,
    amount: BigUInt
  ) async throws -> String {
    let rpcURL = try getRpcURL(chainId: chainId)
    let ethereumFromAddress = EthereumAddress.parse(walletAddress)
    
    let web3 = Web3(rpcURL: rpcURL)
    let contract = web3.eth.Contract(
      type: GenericERC20Contract.self,
      address: EthereumAddress.parse(contractAddress)
    )
    
    guard let ethereumToAddress = EthereumAddress.parse(toAddress)
    else {
      RainLogger.error("Rain SDK: Error building ERC-20 transfer parameters")
      throw RainError.internalError(details: "Failed to encode ERC-20")
    }
    
    let tx = contract
      .transfer(
        to: ethereumToAddress,
        value: amount
      )
      .createTransaction(
        nonce: nil,
        gasPrice: nil,
        maxFeePerGas: nil,
        maxPriorityFeePerGas: nil,
        gasLimit: nil,
        from: ethereumFromAddress,
        value: 0,
        accessList: [:],
        transactionType: .legacy
      )
    
    guard let tx
    else {
      RainLogger.error("Rain SDK: Error building ERC-20 transfer. Could not encode transfer call")
      throw RainError.internalError(details: "Failed to encode ERC-20")
    }
    
    return tx.data.hex()
  }

  /// Builds ERC-20 `approve(spender, amount)` transaction data — the wallet-side prerequisite
  /// for Rain's Auth Pull, where `spender` is the user's collateral contract.
  ///
  /// `amount` is in base units; `BigUInt` max encodes an unlimited allowance and `0` revokes.
  func buildERC20ApproveData(
    chainId: Int,
    contractAddress: String,
    walletAddress: String,
    spender: String,
    amount: BigUInt
  ) async throws -> String {
    // `BigUInt` is unbounded but the ABI word it encodes into is not, so a larger value would be
    // silently truncated into a completely different allowance. Checked here as well as at the
    // scaling layer, because this entry point also takes base units directly.
    guard amount <= RainTokenAllowance.unlimitedRawAmount else {
      throw RainError.invalidAmount(
        amount: amount.description,
        reason: "approval amount must fit in uint256"
      )
    }
    let rpcURL = try getRpcURL(chainId: chainId)
    let ethereumFromAddress = EthereumAddress.parse(walletAddress)

    let web3 = Web3(rpcURL: rpcURL)
    let contract = web3.eth.Contract(
      type: GenericERC20Contract.self,
      address: EthereumAddress.parse(contractAddress)
    )

    guard let ethereumSpenderAddress = EthereumAddress.parse(spender)
    else {
      RainLogger.error("Rain SDK: Error building ERC-20 approve parameters")
      throw RainError.internalError(details: "Failed to encode ERC-20 approve")
    }

    let tx = contract
      .approve(
        spender: ethereumSpenderAddress,
        value: amount
      )
      .createTransaction(
        nonce: nil,
        gasPrice: nil,
        maxFeePerGas: nil,
        maxPriorityFeePerGas: nil,
        gasLimit: nil,
        from: ethereumFromAddress,
        value: 0,
        accessList: [:],
        transactionType: .legacy
      )

    guard let tx
    else {
      RainLogger.error("Rain SDK: Error building ERC-20 approve. Could not encode approve call")
      throw RainError.internalError(details: "Failed to encode ERC-20 approve")
    }

    return tx.data.hex()
  }
}

// MARK: - Helpers

private extension TransactionBuilderService {
  /// Get RPC URL for a specific chain ID
  /// - Parameter chainId: The chain identifier
  /// - Returns: RPC URL string
  /// - Throws: RainError if RPC URL not found
  func getRpcURL(chainId: Int) throws -> String {
    guard let config = networkConfigsByChainId[chainId] else {
      RainLogger.error("Rain SDK: Error getting RPC URL. Chain ID \(chainId) not found in network configs")
      throw RainError.invalidConfig(details: "No RPC endpoint configured for chainId=\(chainId)")
    }

    guard config.rpcUrl.isValidHTTPURL() else {
      RainLogger.error("Rain SDK: Error getting RPC URL. Invalid RPC URL for chain ID \(chainId)")
      throw RainError.invalidConfig(
        details: "Invalid RPC URL for chainId=\(chainId): \(config.rpcUrl)"
      )
    }
    
    return config.rpcUrl
  }
  
}
