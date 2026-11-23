import Testing
import Foundation
@_spi(RainAdapter) @testable import RainCore

@Suite("Base58")
struct Base58Tests {
  @Test("empty round-trips to empty")
  func emptyRoundTrips() throws {
    #expect(Base58.encode([]) == "")
    #expect(try Base58.decode("") == [])
  }

  @Test("single-byte vectors")
  func singleByteVectors() throws {
    #expect(Base58.encode([0]) == "1")
    #expect(Base58.encode([1]) == "2")
    #expect(Base58.encode([57]) == "z")
    #expect(Base58.encode([58]) == "21")
    #expect(try Base58.decode("1") == [0])
    #expect(try Base58.decode("2") == [1])
    #expect(try Base58.decode("z") == [57])
    #expect(try Base58.decode("21") == [58])
  }

  @Test("leading zero bytes map to leading ones")
  func leadingZeros() throws {
    #expect(Base58.encode([0, 1]) == "12")
    #expect(try Base58.decode("12") == [0, 1])
    #expect(try Base58.decode("11") == [0, 0])
    #expect(Base58.encode([0, 0]) == "11")
  }

  @Test("system program id is 32 all-zero bytes")
  func systemProgramId() throws {
    let systemProgram = String(repeating: "1", count: 32)
    #expect(try Base58.decode(systemProgram) == [UInt8](repeating: 0, count: 32))
    #expect(Base58.encode([UInt8](repeating: 0, count: 32)) == systemProgram)
  }

  @Test("round-trips 32 and 64 byte values including high bytes")
  func roundTrips() throws {
    let pubkey = (0..<32).map { UInt8(($0 * 7 + 3) & 0xFF) }
    let signature = (0..<64).map { UInt8((255 - $0) & 0xFF) }
    let leadingZero = [UInt8](repeating: 0, count: 3) + (0..<29).map { UInt8(0x80 | $0) }
    #expect(try Base58.decode(Base58.encode(pubkey)) == pubkey)
    #expect(try Base58.decode(Base58.encode(signature)) == signature)
    #expect(try Base58.decode(Base58.encode(leadingZero)) == leadingZero)
  }

  @Test("decode rejects characters outside the alphabet")
  func rejectsInvalidChars() {
    #expect(throws: RainError.self) { try Base58.decode("0OIl") }
  }
}
