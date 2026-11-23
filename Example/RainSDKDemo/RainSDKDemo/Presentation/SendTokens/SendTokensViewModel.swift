import Foundation
import RainCore

/// Sends the native token or a fungible token (ERC-20 on EVM, SPL on Solana) from the wallet.
@MainActor
final class SendTokensViewModel: ObservableObject {
  @Published var isTokenMode = false
  @Published var recipientAddress = WalletChain.avalancheFuji.defaultRecipient
  @Published var amount = "0.001"
  @Published var contractAddress = WalletChain.avalancheFuji.defaultTokenAddress
  @Published private(set) var isSending = false
  @Published private(set) var txHash: String?
  @Published private(set) var errorText: String?

  private let session: RainSDKService
  /// The chain the form is currently seeded for, so re-seeding is idempotent.
  private var seededChain: WalletChain?
  /// The in-flight send, if any, so a chain switch can cancel it.
  private var sendTask: Task<Void, Never>?

  init() {
    self.session = .shared
  }

  /// Seeds the form for `chain`. The token address and recipient are chain-specific, so switching
  /// chains re-fills them. No-op when `chain` is already seeded.
  func onChainChanged(_ chain: WalletChain) {
    guard seededChain != chain else { return }
    seededChain = chain
    sendTask?.cancel()
    sendTask = nil
    contractAddress = chain.defaultTokenAddress
    recipientAddress = chain.defaultRecipient
    isSending = false
    txHash = nil
    errorText = nil
  }

  func onSendModeChanged(isToken: Bool) {
    isTokenMode = isToken
    txHash = nil
    errorText = nil
  }

  func sendNative(chain: WalletChain) {
    guard let amountDecimal = parsedAmount() else { return }
    guard validateRecipient(chain: chain) else { return }

    SampleLog.i(
      "Send.native",
      "to=\(recipientAddress) amount=\(amountDecimal) \(chain.nativeSymbol)"
    )
    isSending = true
    errorText = nil
    txHash = nil

    sendTask = Task {
      do {
        let result = try await session.requireClient().sendNative(
          chainId: chain.chainId,
          to: recipientAddress,
          amount: amountDecimal
        )
        guard !Task.isCancelled else { return }
        SampleLog.i("Send.native", "success txHash=\(result.transactionHash)")
        txHash = result.transactionHash
      } catch {
        guard !Task.isCancelled else { return }
        SampleLog.e("Send.native", "failed: \(error.localizedDescription)")
        errorText = "Send failed: \(error.localizedDescription)"
      }
      isSending = false
    }
  }

  /// Sends a fungible token: an ERC-20 on EVM chains, an SPL token on Solana. Both go through the
  /// same `sendToken` call — the SDK routes on the chain id, resolves the token's decimals itself,
  /// and on Solana creates the recipient's token account if they lack one.
  func sendTokenTransfer(chain: WalletChain) {
    let logTag = chain.isSolana ? "Send.spl" : "Send.erc20"
    guard let amountDecimal = parsedAmount() else { return }
    guard !contractAddress.isEmpty else {
      errorText = "\(chain.tokenAddressLabel) is required"
      return
    }
    guard chain.isValidAddress(contractAddress) else {
      errorText = "\(chain.tokenAddressLabel) is not a valid \(chain.displayName) address"
      return
    }
    guard validateRecipient(chain: chain) else { return }

    SampleLog.i(
      logTag,
      "token=\(contractAddress) to=\(recipientAddress) amount=\(amountDecimal) (decimals resolved by SDK)"
    )
    isSending = true
    errorText = nil
    txHash = nil

    sendTask = Task {
      do {
        // Decimals are resolved by the SDK — from the token registry or an on-chain `decimals()`
        // read on EVM, and from the mint account on Solana.
        let result = try await session.requireClient().sendToken(
          chainId: chain.chainId,
          contractAddress: contractAddress,
          to: recipientAddress,
          amount: amountDecimal
        )
        guard !Task.isCancelled else { return }
        SampleLog.i(logTag, "success txHash=\(result.transactionHash)")
        txHash = result.transactionHash
      } catch {
        guard !Task.isCancelled else { return }
        SampleLog.e(logTag, "failed: \(error.localizedDescription)")
        errorText = "Send failed: \(error.localizedDescription)"
      }
      isSending = false
    }
  }

  private func parsedAmount() -> Decimal? {
    guard let value = Decimal(string: amount), value > 0 else {
      errorText = "Invalid amount"
      return nil
    }
    return value
  }

  private func validateRecipient(chain: WalletChain) -> Bool {
    guard !recipientAddress.isEmpty else {
      errorText = "Recipient address is required"
      return false
    }
    guard chain.isValidAddress(recipientAddress) else {
      errorText = "Recipient is not a valid \(chain.displayName) address"
      return false
    }
    return true
  }
}
