import Foundation
import Web3

/// Solana implementation of `ChainReader` — the "future Solana reader" anticipated by the
/// protocol docs. Reads native SOL balances over Solana JSON-RPC (`getBalance`) and SPL token
/// balances via `getTokenAccountsByOwner`.
///
/// Token *metadata* stays out of scope: Solana keeps symbol / name off-chain (Metaplex), so
/// `getSymbol` / `getName` still throw rather than invent values.
internal final class SolanaChainReader: ChainReader, @unchecked Sendable {
  private let solanaRpcClient: SolanaRpcClient

  internal init(solanaRpcClient: SolanaRpcClient) {
    self.solanaRpcClient = solanaRpcClient
  }

  /// Convenience init that builds the RPC client from a list of network configs.
  internal convenience init(networkConfigs: [NetworkConfig], jsonRpcClient: JsonRpcClient = JsonRpcClient()) {
    self.init(solanaRpcClient: SolanaRpcClient(jsonRpcClient: jsonRpcClient, networkConfigs: networkConfigs))
  }

  func getNativeBalance(chainId: Int, walletAddress: String) async throws -> Decimal {
    try validate(solanaAddress: walletAddress)
    let lamports = try await solanaRpcClient.getBalanceLamports(chainId: chainId, address: walletAddress)
    return SolanaConverter.lamportsToSol(lamports)
  }

  func getBalance(
    chainId: Int,
    walletAddress: String,
    token: Token,
    tokenInfo: TokenInfo?
  ) async throws -> Balance {
    try validate(solanaAddress: walletAddress)
    switch token {
    case .native:
      let lamports = try await solanaRpcClient.getBalanceLamports(chainId: chainId, address: walletAddress)
      let native = SolanaChains.nativeCurrency
      return Balance(
        token: .native,
        chainId: chainId,
        rawAmount: lamports,
        decimals: native.decimals,
        symbol: native.symbol,
        name: native.name
      )
    case .contract(let mint):
      return try await splBalance(
        chainId: chainId,
        walletAddress: walletAddress,
        mint: mint,
        tokenInfo: tokenInfo
      )
    }
  }

  /// Balance of `mint` for `walletAddress`, read from the wallet's associated token account.
  ///
  /// A wallet that has never held the mint has no such account, which is a zero balance rather
  /// than an error. Decimals come from the mint itself; `tokenInfo` only supplies naming, since
  /// SPL symbols live in off-chain metadata the SDK does not read.
  private func splBalance(
    chainId: Int,
    walletAddress: String,
    mint: String,
    tokenInfo: TokenInfo?
  ) async throws -> Balance {
    guard let mintInfo = try await solanaRpcClient.getMintInfo(chainId: chainId, mint: mint) else {
      throw RainError.tokenNotFound(token: mint, chainId: chainId)
    }
    let tokenAccount = try SolanaProgramAddress.associatedTokenAddress(
      owner: walletAddress,
      mint: mint,
      tokenProgramId: mintInfo.tokenProgramId
    )
    let account = try await solanaRpcClient.getTokenAccount(chainId: chainId, address: tokenAccount)

    return Balance(
      token: .contract(address: mint),
      chainId: chainId,
      rawAmount: account?.rawAmount ?? 0,
      decimals: mintInfo.decimals,
      symbol: tokenInfo?.symbol,
      name: tokenInfo?.name
    )
  }

  /// Native SOL plus every SPL token the wallet actually holds.
  ///
  /// Solana has no token registry to enumerate, so the mints are discovered from the wallet's own
  /// token accounts rather than from `tokens` — which is used only to attach symbol / name when a
  /// discovered mint happens to be registered. Discovery is best-effort: if it fails, the native
  /// balance is still returned.
  func getBalances(
    chainId: Int,
    walletAddress: String,
    tokens: [TokenInfo]
  ) async throws -> [Balance] {
    var output = [
      try await getBalance(chainId: chainId, walletAddress: walletAddress, token: .native, tokenInfo: nil)
    ]

    let accounts = await discoverTokenAccounts(chainId: chainId, walletAddress: walletAddress)
    let metadata = Dictionary(tokens.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })

    // A wallet can hold more than one token account for the same mint, so report the total per
    // mint rather than one entry per account.
    var rawByMint: [String: BigUInt] = [:]
    var decimalsByMint: [String: Int] = [:]
    var mintOrder: [String] = []
    for account in accounts {
      if rawByMint[account.mint] == nil {
        mintOrder.append(account.mint)
        decimalsByMint[account.mint] = account.decimals
      }
      rawByMint[account.mint, default: 0] += account.rawAmount
    }

    for mint in mintOrder {
      let total = rawByMint[mint] ?? 0
      guard total > 0 else { continue }
      let info = metadata[mint]
      output.append(
        Balance(
          token: .contract(address: mint),
          chainId: chainId,
          rawAmount: total,
          decimals: decimalsByMint[mint] ?? info?.decimals ?? 0,
          symbol: info?.symbol,
          name: info?.name
        )
      )
    }
    return output
  }

  /// Token accounts held under either token program, enumerated concurrently and per-program
  /// tolerant: a failed enumeration is logged and its holdings omitted, mirroring how the EVM
  /// reader treats one unreadable token.
  func discoverTokenAccounts(
    chainId: Int,
    walletAddress: String
  ) async -> [SolanaRpcClient.TokenAccount] {
    // Indexed so the merged list stays in program order however the two calls interleave —
    // balances are user-visible and should not reshuffle between reads.
    await withTaskGroup(of: (Int, [SolanaRpcClient.TokenAccount]).self) { group in
      let programs = [SolanaPrograms.splToken, SolanaPrograms.token2022]
      for (index, program) in programs.enumerated() {
        group.addTask { [solanaRpcClient] in
          do {
            return (
              index,
              try await solanaRpcClient.getTokenAccountsByOwner(
                chainId: chainId, owner: walletAddress, tokenProgram: program
              )
            )
          } catch {
            RainLogger.warning(
              """
              Rain SDK: token-account enumeration failed for program \(program) \
              (chainId=\(chainId)) — omitting its holdings: \(error)
              """
            )
            return (index, [])
          }
        }
      }
      var byProgram = [[SolanaRpcClient.TokenAccount]](repeating: [], count: programs.count)
      for await (index, accounts) in group {
        byProgram[index] = accounts
      }
      return byProgram.flatMap { $0 }
    }
  }

  /// `decimals` is ignored: the mint's on-chain scale is authoritative for SPL amounts.
  func getERC20Balance(
    chainId: Int,
    tokenAddress: String,
    walletAddress: String,
    decimals: Int?
  ) async throws -> Decimal {
    let balance = try await splBalance(
      chainId: chainId,
      walletAddress: walletAddress,
      mint: tokenAddress,
      tokenInfo: nil
    )
    return EthereumConverter.baseUnitsToDecimal(
      balance.rawAmount,
      decimals: balance.decimals
    )
  }

  /// A mint's scale, read from the mint account.
  func getDecimals(chainId: Int, tokenAddress: String) async throws -> Int {
    guard let mint = try await solanaRpcClient.getMintInfo(chainId: chainId, mint: tokenAddress) else {
      throw RainError.tokenNotFound(token: tokenAddress, chainId: chainId)
    }
    return mint.decimals
  }

  /// `nil`: an SPL mint carries no on-chain symbol. Names live in Metaplex token metadata, a
  /// separate program the SDK does not read — so this reports "unknown" rather than throwing,
  /// which would abort metadata enrichment for a token whose balance is perfectly readable.
  func getSymbol(chainId: Int, tokenAddress: String) async throws -> String? {
    nil
  }

  /// `nil`, for the same reason as ``getSymbol(chainId:tokenAddress:)``.
  func getName(chainId: Int, tokenAddress: String) async throws -> String? {
    nil
  }

  /// SPL has no ERC-20 allowance: a delegate is approved on a token account, not by
  /// (owner, spender) pair on the mint. Throws rather than reporting a misleading zero.
  func getERC20Allowance(
    chainId: Int,
    tokenAddress: String,
    owner: String,
    spender: String,
    atBlock: String
  ) async throws -> BigUInt {
    throw RainError.internalError(
      details: "ERC-20 allowances are not supported on Solana (chainId=\(chainId))"
    )
  }

  func getTransactionReceipt(
    chainId: Int,
    transactionHash: String
  ) async throws -> MinedReceipt? {
    throw RainError.internalError(
      details: "EVM transaction receipts are not supported on Solana (chainId=\(chainId))"
    )
  }

  private func validate(solanaAddress address: String) throws {
    let valid = ((try? Base58.decode(address))?.count == 32)
    guard valid else {
      throw RainError.internalError(details: "Invalid Solana wallet address: \(address)")
    }
  }
}
