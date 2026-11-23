import Foundation
import RainCore

/// A collateral token balance, sourced from the Rain API (tokens sit in the contract, not the
/// user's wallet).
struct CollateralTokenBalance: Identifiable {
  let symbol: String
  let name: String
  let address: String
  /// From `RainSdk.tokenMetadata`; `nil` when unresolved. The API balance is already in whole
  /// tokens, so display needs no decimals — never guess them for anything that scales an amount.
  let decimals: Int?
  let balance: Decimal
  let exchangeRate: Double

  var id: String { address }

  var displayAddress: String {
    address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
  }
}

/// A contract token the wallet holds, discovered on-chain with its metadata already resolved.
struct WalletTokenBalance: Identifiable {
  let address: String
  let symbol: String?
  let name: String?
  let decimals: Int
  let balance: Decimal

  var id: String { address }

  var displayAddress: String {
    address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
  }

  /// "USD Coin (USDC)", or just the symbol / name when one is missing.
  var displayName: String {
    let name = (name ?? "").isEmpty ? nil : name
    let symbol = (symbol ?? "").isEmpty ? nil : symbol
    switch (name, symbol) {
    case let (name?, symbol?): return "\(name) (\(symbol))"
    case let (nil, symbol?): return symbol
    case let (name?, nil): return name
    default: return "Unnamed token"
    }
  }

  /// The unit printed after an amount: the symbol when known, else the truncated address. Never
  /// blank, so a balance always says which token it is — an SPL mint has no on-chain symbol.
  var displayUnit: String {
    let symbol = symbol ?? ""
    return symbol.isEmpty ? displayAddress : symbol
  }

  /// The balance at the token's own scale, trailing zeros stripped.
  var formattedBalance: String { balance.plainString }
}

/// Fetches the collateral contract's balances (Rain API) and the wallet's own balances (on-chain).
@MainActor
final class BalancesViewModel: ObservableObject {
  // Wallet (on-chain) section
  @Published private(set) var internalWalletAddress = ""
  @Published private(set) var isLoading = false
  @Published private(set) var nativeBalance: String?
  @Published private(set) var walletTokenBalances: [WalletTokenBalance] = []
  @Published private(set) var errorMessage: String?

  // Collateral (Rain API) section
  @Published private(set) var collateralWalletAddress = ""
  @Published private(set) var isCollateralLoading = false
  @Published private(set) var collateralBalances: [CollateralTokenBalance] = []
  @Published private(set) var collateralError: String?

  private let session: RainSDKService

  init() {
    self.session = .shared
  }

  func loadWalletAddress(chain: WalletChain) async {
    guard let client = try? session.requireClient() else { return }
    do {
      let address = try await client.getWalletAddress(chainId: chain.chainId)
      SampleLog.d("Balances.address", "wallet address=\(address)")
      internalWalletAddress = address
    } catch {
      SampleLog.w("Balances.address", "getWalletAddress failed: \(error.localizedDescription)")
    }
  }

  func fetchBalances(chain: WalletChain) async {
    guard let client = try? session.requireClient() else {
      SampleLog.w("Balances.fetch", "SDK not initialized")
      errorMessage = "SDK not initialized"
      return
    }

    SampleLog.i("Balances.fetch", "fetching balances chain=\(chain.displayName)")
    isLoading = true
    errorMessage = nil

    do {
      // The SDK resolves token decimals / symbol itself, so the Balance API takes only a token
      // discriminator (no decimals argument).
      let native = try await client.getBalance(chainId: chain.chainId, token: .native)
      SampleLog.d("Balances.fetch", "native=\(native.formatted) \(native.symbol ?? "")")

      // Discover every non-zero token the wallet holds — ERC-20s on EVM, SPL tokens on Solana.
      // Each Balance already carries the resolved symbol / name / decimals, so the user picks a
      // token instead of typing a contract or mint address plus decimals.
      let discovered = try await client.getTokenBalances(chainId: chain.chainId)
        .compactMap { balance -> WalletTokenBalance? in
          guard case .contract(let address) = balance.token else { return nil }
          return WalletTokenBalance(
            address: address,
            symbol: balance.symbol,
            name: balance.name,
            decimals: balance.decimals,
            balance: balance.decimalAmount
          )
        }
        .filter { $0.balance > 0 }

      SampleLog.i(
        "Balances.fetch",
        "success — discovered \(discovered.count) \(chain.tokenStandard) token(s)"
      )
      nativeBalance = "\(native.formatted) \(native.symbol ?? chain.nativeSymbol)"
      walletTokenBalances = discovered
    } catch {
      SampleLog.e("Balances.fetch", "failed: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  func fetchCollateralBalances(chain: WalletChain) async {
    guard session.isRainApiConfigured else {
      SampleLog.w("Balances.collateral", "Rain API not configured")
      collateralError = "Rain Api-Key and User ID required"
      return
    }

    SampleLog.i("Balances.collateral", "fetching collateral contract chain=\(chain.displayName)")
    isCollateralLoading = true
    collateralError = nil

    do {
      // The collateral contract comes from the Rain API — the host's call, not the SDK's.
      guard let contract = try await session.fetchCollateralContract(for: chain) else {
        SampleLog.w("Balances.collateral", "no collateral contract for \(chain.displayName)")
        collateralError = "No collateral contract on \(chain.displayName)"
        isCollateralLoading = false
        return
      }

      SampleLog.i(
        "Balances.collateral",
        "success — address=\(contract.proxyAddress) tokens=\(contract.tokens.count)"
      )
      // Collateral balances come from the API, not on-chain: the tokens are deposited into the
      // smart contract, so the user's wallet doesn't hold them.
      collateralWalletAddress = contract.proxyAddress
      collateralBalances = contract.tokens.map { token in
        CollateralTokenBalance(
          symbol: token.symbol ?? token.name ?? "Unknown",
          name: token.name ?? "",
          address: token.address,
          decimals: token.decimals,
          balance: token.balanceAmount ?? 0,
          exchangeRate: token.exchangeRate
        )
      }
    } catch {
      SampleLog.e("Balances.collateral", "failed: \(error.localizedDescription)")
      collateralError = error.localizedDescription
    }
    isCollateralLoading = false
  }
}
