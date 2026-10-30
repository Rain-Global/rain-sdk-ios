import Foundation
import Web3

/// Thin Solana JSON-RPC helper layered on the shared `JsonRpcClient`. Solana RPC returns JSON
/// objects/numbers rather than the hex strings EVM uses, so it needs the raw `call()` surface
/// (not `callForHexResult`).
///
/// Covers the three calls the Solana wallet path needs: the native balance, a recent blockhash
/// for an outgoing transfer, and the signature of a just-submitted transfer.
@_spi(RainAdapter) public final class SolanaRpcClient: Sendable {
  private let jsonRpcClient: JsonRpcClient
  private let networkConfigResolver: @Sendable (Int) -> NetworkConfig?

  internal init(
    jsonRpcClient: JsonRpcClient = JsonRpcClient(),
    networkConfigResolver: @escaping @Sendable (Int) -> NetworkConfig?
  ) {
    self.jsonRpcClient = jsonRpcClient
    self.networkConfigResolver = networkConfigResolver
  }

  /// Convenience init that builds the resolver from a list of network configs.
  internal convenience init(
    jsonRpcClient: JsonRpcClient = JsonRpcClient(),
    networkConfigs: [NetworkConfig]
  ) {
    let lookup = Dictionary(uniqueKeysWithValues: networkConfigs.map { ($0.chainId, $0) })
    self.init(jsonRpcClient: jsonRpcClient, networkConfigResolver: { lookup[$0] })
  }

  /// Native SOL balance in lamports via `getBalance`.
  func getBalanceLamports(chainId: Int, address: String) async throws -> BigUInt {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(rpcUrl: rpcUrl, method: "getBalance", params: [address])
    guard let result = response["result"] as? [String: Any],
          let value = result["value"] as? NSNumber else {
      throw RainError.internalError(details: "Unexpected getBalance response for \(address)")
    }
    // Parse via the decimal string form: `BigUInt(UInt64)` is ambiguous once BigInt is in
    // module scope, and the string init is the codebase's established idiom.
    return BigUInt(value.stringValue) ?? 0
  }

  /// The lamports an account of `dataLength` bytes must hold to be rent exempt.
  func getMinimumBalanceForRentExemption(chainId: Int, dataLength: Int) async throws -> BigUInt {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "getMinimumBalanceForRentExemption",
      params: [dataLength]
    )
    guard let value = response["result"] as? NSNumber else {
      throw RainError.internalError(
        details: "Unexpected getMinimumBalanceForRentExemption response for \(dataLength) bytes"
      )
    }
    return BigUInt(value.stringValue) ?? 0
  }

  /// Most recent blockhash via `getLatestBlockhash`, used as a transfer's `recentBlockhash`.
  func getLatestBlockhash(chainId: Int) async throws -> String {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "getLatestBlockhash",
      params: [["commitment": "finalized"]]
    )
    guard let result = response["result"] as? [String: Any],
          let value = result["value"] as? [String: Any],
          let blockhash = value["blockhash"] as? String,
          !blockhash.isEmpty else {
      throw RainError.internalError(details: "Unexpected getLatestBlockhash response")
    }
    return blockhash
  }

  // MARK: - Accounts (SPL)

  /// The fields of a `getAccountInfo` result the SDK reads. Not `Sendable`: `parsedInfo` is the
  /// raw JSON dictionary, which is read on the calling task and never handed across one.
  struct AccountInfo {
    /// Program that owns the account — the System Program for a plain wallet.
    let ownerProgram: String
    /// `jsonParsed` account type, e.g. `mint` or `account`; `nil` when the cluster can't parse it.
    let parsedType: String?
    let parsedInfo: [String: Any]?
  }

  /// An SPL mint: its scale, and the token program that owns it (classic SPL Token or
  /// Token-2022 — the two derive different associated token accounts).
  @_spi(RainAdapter) public struct MintInfo: Sendable, Equatable {
    public let address: String
    public let decimals: Int
    public let tokenProgramId: String
  }

  /// An SPL token account: which mint it holds, for whom, and how much.
  @_spi(RainAdapter) public struct TokenAccount: Sendable, Equatable {
    public let address: String
    public let mint: String
    public let owner: String
    public let rawAmount: BigUInt
    public let decimals: Int
  }

  /// Outcome of a `simulateTransaction` dry run. `error` is `nil` when the transaction would
  /// succeed.
  struct Simulation: Sendable, Equatable {
    let error: String?
    let logs: [String]

    var succeeded: Bool { error == nil }

    /// The runtime refused the payer's lamports rather than the program's logic: a fee or rent
    /// shortfall.
    var fundsShortfall: Bool {
      guard let error else { return false }
      return error.contains("InsufficientFundsForFee") || error.contains("InsufficientFundsForRent")
    }
  }

  /// `getAccountInfo` for `address`, or `nil` when no account exists there.
  ///
  /// Read at `confirmed` rather than the default `finalized`: a token account created moments
  /// earlier must be visible, or the SDK would try to create it a second time.
  func getAccountInfo(chainId: Int, address: String) async throws -> AccountInfo? {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "getAccountInfo",
      params: [address, ["encoding": "jsonParsed", "commitment": "confirmed"]]
    )
    guard let result = response["result"] as? [String: Any] else {
      throw RainError.internalError(details: "Unexpected getAccountInfo response for \(address)")
    }
    // `value` is JSON null for an address that holds no account.
    guard let value = result["value"] as? [String: Any] else { return nil }

    // `data` is a [base64, encoding] array for accounts the cluster cannot parse (a plain wallet,
    // for one), and an object only for programs it understands.
    let parsed = (value["data"] as? [String: Any])?["parsed"] as? [String: Any]
    return AccountInfo(
      ownerProgram: value["owner"] as? String ?? "",
      parsedType: (parsed?["type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      parsedInfo: parsed?["info"] as? [String: Any]
    )
  }

  /// Whether anything exists at `address` — used to decide if a token account must be created.
  func accountExists(chainId: Int, address: String) async throws -> Bool {
    try await getAccountInfo(chainId: chainId, address: address) != nil
  }

  /// An account's owning program plus its undecoded bytes.
  struct RawAccount: Sendable, Equatable {
    let ownerProgram: String
    let data: [UInt8]
  }

  /// `getAccountInfo` with `base64` encoding, for accounts the cluster cannot parse — Anchor
  /// accounts like Rain's collateral and coordinator, whose layouts the SDK decodes itself.
  func getRawAccount(chainId: Int, address: String) async throws -> RawAccount? {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "getAccountInfo",
      params: [address, ["encoding": "base64", "commitment": "confirmed"]]
    )
    guard let result = response["result"] as? [String: Any] else {
      throw RainError.internalError(details: "Unexpected getAccountInfo response for \(address)")
    }
    guard let value = result["value"] as? [String: Any] else { return nil }

    // `data` is a [base64, encoding] pair for a base64 read.
    let base64 = (value["data"] as? [Any])?.first as? String ?? ""
    guard let decoded = Data(base64Encoded: base64) else {
      throw RainError.internalError(details: "Undecodable account data for \(address)")
    }
    return RawAccount(
      ownerProgram: value["owner"] as? String ?? "",
      data: [UInt8](decoded)
    )
  }

  /// Decimals and owning token program for `mint`, or `nil` when `mint` is not an SPL mint on this
  /// cluster (missing account, or an account owned by some other program).
  ///
  /// The owning program matters twice over: it is the program a transfer must be addressed to, and
  /// it is a seed of the associated-token-account address.
  @_spi(RainAdapter) public func getMintInfo(chainId: Int, mint: String) async throws -> MintInfo? {
    guard let account = try await getAccountInfo(chainId: chainId, address: mint) else { return nil }
    guard SolanaPrograms.isTokenProgram(account.ownerProgram), account.parsedType == "mint" else {
      return nil
    }
    guard let decimals = (account.parsedInfo?["decimals"] as? NSNumber)?.intValue,
          (0...255).contains(decimals) else {
      throw RainError.internalError(details: "Mint \(mint) returned no usable decimals")
    }
    return MintInfo(address: mint, decimals: decimals, tokenProgramId: account.ownerProgram)
  }

  /// The SPL token account at `address`, or `nil` when it does not exist or is not one.
  @_spi(RainAdapter) public func getTokenAccount(chainId: Int, address: String) async throws -> TokenAccount? {
    guard let account = try await getAccountInfo(chainId: chainId, address: address) else { return nil }
    guard SolanaPrograms.isTokenProgram(account.ownerProgram),
          account.parsedType == "account",
          let info = account.parsedInfo else {
      return nil
    }
    guard let parsed = Self.parseTokenAccount(address: address, info: info) else {
      throw RainError.internalError(details: "Token account \(address) returned no tokenAmount")
    }
    return parsed
  }

  /// Every token account `owner` holds under `tokenProgram`, via `getTokenAccountsByOwner`.
  ///
  /// This is how SPL holdings are *discovered*: unlike EVM, where balances are read per known
  /// contract, the cluster enumerates a wallet's token accounts directly — so no registry of mints
  /// is needed. Call once per token program; the two programs hold separate accounts.
  func getTokenAccountsByOwner(
    chainId: Int,
    owner: String,
    tokenProgram: String
  ) async throws -> [TokenAccount] {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "getTokenAccountsByOwner",
      params: [
        owner,
        ["programId": tokenProgram],
        ["encoding": "jsonParsed", "commitment": "confirmed"]
      ]
    )
    guard let result = response["result"] as? [String: Any],
          let value = result["value"] as? [[String: Any]] else {
      throw RainError.internalError(
        details: "Unexpected getTokenAccountsByOwner response for \(owner)"
      )
    }
    return value.compactMap { row in
      guard let address = row["pubkey"] as? String,
            let info = ((row["account"] as? [String: Any])?["data"] as? [String: Any])?["parsed"]
              .flatMap({ ($0 as? [String: Any])?["info"] as? [String: Any] }) else {
        return nil
      }
      let parsed = Self.parseTokenAccount(address: address, info: info)
      if parsed == nil {
        RainLogger.warning("Rain SDK: skipping malformed token account \(address) — missing tokenAmount")
      }
      return parsed
    }
  }

  /// Builds a `TokenAccount` from a `jsonParsed` token-account `info`, or `nil` when the
  /// `tokenAmount` fields are missing or unreadable — defaulting them would mis-scale a real
  /// balance.
  private static func parseTokenAccount(address: String, info: [String: Any]) -> TokenAccount? {
    guard let tokenAmount = info["tokenAmount"] as? [String: Any],
          let amountString = tokenAmount["amount"] as? String,
          let amount = BigUInt(amountString),
          let decimals = (tokenAmount["decimals"] as? NSNumber)?.intValue,
          decimals >= 0 else {
      return nil
    }
    return TokenAccount(
      address: address,
      mint: info["mint"] as? String ?? "",
      owner: info["owner"] as? String ?? "",
      rawAmount: amount,
      decimals: decimals
    )
  }

  // MARK: - Simulation

  /// Dry-runs `base64Transaction` against the cluster before it is submitted for signing.
  ///
  /// The transaction is still unsigned at this point — the wallet provider holds the key — so
  /// signature verification is off and the cluster substitutes a current blockhash. Everything
  /// that actually matters here (funds, account ownership, mint/decimals agreement, rent) is still
  /// checked, which is what turns a silent on-chain failure into an upfront error.
  func simulateTransaction(chainId: Int, base64Transaction: String) async throws -> Simulation {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "simulateTransaction",
      params: [
        base64Transaction,
        [
          "encoding": "base64",
          "sigVerify": false,
          "replaceRecentBlockhash": true,
          "commitment": "confirmed"
        ]
      ]
    )
    guard let result = response["result"] as? [String: Any],
          let value = result["value"] as? [String: Any] else {
      throw RainError.internalError(details: "Unexpected simulateTransaction response")
    }
    let error = (value["err"] is NSNull ? nil : value["err"]).map { "\($0)" }
    let logs = (value["logs"] as? [String])?.filter { !$0.isEmpty } ?? []
    return Simulation(error: error, logs: logs)
  }

  /// The most recent transaction signature involving `address`, or `nil` if none. Used as a
  /// defensive fallback when Turnkey's status response carries no Solana signature.
  @_spi(RainAdapter) public func getLatestSignature(chainId: Int, address: String) async throws -> String? {
    let rpcUrl = try resolveRpcUrl(chainId: chainId)
    let response = try await jsonRpcClient.call(
      rpcUrl: rpcUrl,
      method: "getSignaturesForAddress",
      params: [address, ["limit": 1]]
    )
    guard let results = response["result"] as? [[String: Any]] else {
      throw RainError.internalError(
        details: "Unexpected getSignaturesForAddress response for \(address)"
      )
    }
    guard let signature = results.first?["signature"] as? String, !signature.isEmpty else {
      return nil
    }
    return signature
  }

  /// Resolves and validates the RPC URL for `chainId`, mirroring `EVMChainReader`.
  private func resolveRpcUrl(chainId: Int) throws -> String {
    guard let config = networkConfigResolver(chainId) else {
      throw RainError.invalidConfig(details: "No RPC endpoint configured for chainId=\(chainId)")
    }
    guard URL(string: config.rpcUrl) != nil else {
      throw RainError.invalidConfig(
        details: "Invalid RPC URL for chainId=\(chainId): \(config.rpcUrl)"
      )
    }
    return config.rpcUrl
  }
}
