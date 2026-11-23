import Testing
import Foundation
import Web3
@_spi(RainAdapter) @testable import RainCore

@Suite("SolanaConverter")
struct SolanaConverterTests {
  @Test("lamportsToSol divides by 1e9")
  func lamportsToSol() {
    // Both overloads (BigUInt and UInt64) are exact Decimal divisions.
    #expect(SolanaConverter.lamportsToSol(BigUInt(2_500_000_000)).description == "2.5")
    #expect(SolanaConverter.lamportsToSol(BigUInt(1)).description == "0.000000001")
    #expect(SolanaConverter.lamportsToSol(UInt64(1)).description == "0.000000001")
  }
}
