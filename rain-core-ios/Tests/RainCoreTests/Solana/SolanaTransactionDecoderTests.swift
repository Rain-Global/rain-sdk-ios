import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

@Suite("SolanaTransactionDecoder")
struct SolanaTransactionDecoderTests {
  let from = Base58.encode((0..<32).map { UInt8($0 + 1) })
  let to = Base58.encode((0..<32).map { UInt8($0 + 33) })
  let blockhash = Base58.encode((0..<32).map { UInt8($0 + 65) })

  @Test("decodes the transfer the builder produced")
  func decodesBuilderOutput() throws {
    let lamports: UInt64 = 1_234_500_000
    let hex = try SolanaTransactionBuilder.buildTransferHex(
      from: from, to: to, lamports: lamports, recentBlockhash: blockhash)
    let decoded = SolanaTransactionDecoder.decodeTransfer(hex)
    #expect(decoded?.from == from)
    #expect(decoded?.to == to)
    #expect(decoded?.lamports == lamports)
  }

  @Test("tolerates an optional 0x prefix")
  func tolerates0xPrefix() throws {
    let hex = try SolanaTransactionBuilder.buildTransferHex(
      from: from, to: to, lamports: 1, recentBlockhash: blockhash)
    #expect(SolanaTransactionDecoder.decodeTransfer("0x" + hex)?.lamports == 1)
  }

  @Test("returns nil for non-hex or undecodable input")
  func returnsNilForBadInput() {
    #expect(SolanaTransactionDecoder.decodeTransfer("not-hex!!") == nil)
    #expect(SolanaTransactionDecoder.decodeTransfer("abcd") == nil)
    #expect(SolanaTransactionDecoder.decodeTokenTransfer("not-hex!!") == nil)
  }

  // MARK: - SPL

  private static let owner = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  private static let recipient = "4zvwRjXUKGfvwnParsHAS3HuSVzV5cA4McphgmoCtajS"
  private static let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  private static let source = "FGETo8T8wMcN2wCjav8VK6eh3dLk63evNDPxzLSJra8B"
  private static let destination = "DJcjpsHnWXSucjUpourygEN3mkcQwSHG6d5b2AzLSfSn"

  private func splTransfer(createDestination: Bool) throws -> String {
    try SolanaTransactionBuilder.buildSPLTransferHex(
      owner: Self.owner,
      source: Self.source,
      destination: Self.destination,
      destinationOwner: Self.recipient,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.splToken,
      amount: 1_500_000,
      decimals: 6,
      recentBlockhash: blockhash,
      createDestinationAccount: createDestination
    )
  }

  @Test("decodes the SPL transfer the builder produced")
  func decodesSplTransfer() throws {
    let decoded = try #require(SolanaTransactionDecoder.decodeTokenTransfer(splTransfer(createDestination: false)))
    #expect(decoded.owner == Self.owner)
    #expect(decoded.source == Self.source)
    #expect(decoded.destination == Self.destination)
    #expect(decoded.mint == Self.mint)
    #expect(decoded.rawAmount == 1_500_000)
    #expect(decoded.decimals == 6)
    // Nothing in this transaction names the wallet behind the destination token account.
    #expect(decoded.destinationOwner == nil)
  }

  @Test("recovers the recipient wallet from an account-creation instruction")
  func recoversDestinationOwner() throws {
    let decoded = try #require(SolanaTransactionDecoder.decodeTokenTransfer(splTransfer(createDestination: true)))
    #expect(decoded.destinationOwner == Self.recipient)
    #expect(decoded.destination == Self.destination)
    #expect(decoded.rawAmount == 1_500_000)
  }

  @Test("a Token-2022 transfer decodes through its own program")
  func decodesToken2022Transfer() throws {
    let hex = try SolanaTransactionBuilder.buildSPLTransferHex(
      owner: Self.owner,
      source: Self.source,
      destination: Self.destination,
      destinationOwner: Self.recipient,
      mint: Self.mint,
      tokenProgramId: SolanaPrograms.token2022,
      amount: 42,
      decimals: 2,
      recentBlockhash: blockhash,
      createDestinationAccount: false
    )
    let decoded = try #require(SolanaTransactionDecoder.decodeTokenTransfer(hex))
    #expect(decoded.rawAmount == 42)
    #expect(decoded.decimals == 2)
    #expect(decoded.mint == Self.mint)
  }

  @Test("the two transfer kinds do not decode as each other")
  func kindsDoNotOverlap() throws {
    let native = try SolanaTransactionBuilder.buildTransferHex(
      from: from, to: to, lamports: 1, recentBlockhash: blockhash)
    #expect(SolanaTransactionDecoder.decodeTokenTransfer(native) == nil)
    #expect(SolanaTransactionDecoder.decodeTransfer(try splTransfer(createDestination: true)) == nil)
  }
}
