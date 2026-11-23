import Testing
import Foundation
@testable import RainCore
@testable import RainTurnkey

/// Tests the raw stamped REST client for Turnkey's history queries. The transport and stamp
/// seams are stubbed, so no test touches the network or the keychain.
@Suite("Turnkey History Client Tests")
struct TurnkeyHistoryClientTests {

  private final class Recorder: @unchecked Sendable {
    var requests: [URLRequest] = []
    var stamped: [(publicKey: String, payload: String)] = []
  }

  private func makeClient(
    status: Int = 200,
    responseBody: String,
    recorder: Recorder
  ) -> TurnkeyHistoryClient {
    TurnkeyHistoryClient(
      baseURL: URL(string: "https://api.test")!,
      stamp: { publicKey, payload in
        recorder.stamped.append((publicKey, payload))
        return ("X-Stamp", "stamp-value")
      },
      transport: { request in
        recorder.requests.append(request)
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: status,
          httpVersion: nil,
          headerFields: nil
        )!
        return (Data(responseBody.utf8), response)
      }
    )
  }

  private func listEth(_ client: TurnkeyHistoryClient) async throws -> TurnkeyEthHistoryResponse {
    try await client.listEthTransactionHistory(
      organizationId: "org-1",
      sessionPublicKey: "session-pub",
      address: "0xabc",
      caip2: "eip155:84532",
      limit: 25
    )
  }

  @Test("eth request posts stamped body to the query path")
  func ethRequestShape() async throws {
    let recorder = Recorder()
    let client = makeClient(responseBody: #"{"transactions":[]}"#, recorder: recorder)

    _ = try await listEth(client)

    let request = try #require(recorder.requests.first)
    #expect(request.url?.absoluteString == "https://api.test/public/v1/query/list_eth_transaction_history")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "X-Stamp") == "stamp-value")

    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    #expect(body?["organizationId"] as? String == "org-1")
    #expect(body?["address"] as? String == "0xabc")
    #expect(body?["caip2"] as? String == "eip155:84532")
    // The API rejects a numeric limit; it must be serialized as a JSON string.
    let pagination = body?["paginationOptions"] as? [String: Any]
    #expect(pagination?["limit"] as? String == "25")
  }

  @Test("stamp signs the exact body that is posted")
  func stampMatchesBody() async throws {
    let recorder = Recorder()
    let client = makeClient(responseBody: #"{"transactions":[]}"#, recorder: recorder)

    _ = try await listEth(client)

    let stamped = try #require(recorder.stamped.first)
    let posted = try #require(recorder.requests.first?.httpBody)
    #expect(stamped.publicKey == "session-pub")
    #expect(Data(stamped.payload.utf8) == posted)
  }

  @Test("eth response parses transactions and ignores unknown fields")
  func ethResponseParsing() async throws {
    let recorder = Recorder()
    let client = makeClient(
      responseBody: """
        {
          "transactions": [
            {
              "transactionHash": "0xhash",
              "block": {"number": "123", "hash": "0xblock", "timestamp": "2026-08-12T10:00:00Z"},
              "status": "CONFIRMED",
              "origin": "TURNKEY",
              "from": "0xfrom",
              "to": "0xto",
              "fee": {"amount": "21", "caip19": "eip155:84532/slip44:60"},
              "transfers": [
                {
                  "direction": "OUT",
                  "asset": {"caip19": "eip155:84532/erc20:0xtoken", "symbol": "USDC", "name": "USD Coin", "decimals": 6},
                  "amount": "2500000",
                  "counterparty": "0xcounterparty",
                  "display": {"crypto": "2.5", "usd": "2.50"}
                }
              ],
              "turnkey": {"sponsored": true, "activityFingerprint": "fp"}
            }
          ],
          "pageInfo": {"hasNextPage": false, "endCursor": "cursor"}
        }
        """,
      recorder: recorder
    )

    let response = try await listEth(client)

    let tx = try #require(response.transactions?.first)
    #expect(tx.transactionHash == "0xhash")
    #expect(tx.block?.number == "123")
    #expect(tx.block?.timestamp == "2026-08-12T10:00:00Z")
    #expect(tx.status == "CONFIRMED")
    #expect(tx.from == "0xfrom")
    #expect(tx.to == "0xto")
    #expect(tx.turnkey?.sponsored == true)
    let transfer = try #require(tx.transfers?.first)
    #expect(transfer.direction == "OUT")
    #expect(transfer.amount == "2500000")
    #expect(transfer.counterparty == "0xcounterparty")
    #expect(transfer.asset?.symbol == "USDC")
    #expect(transfer.asset?.decimals == 6)
    #expect(transfer.display?.crypto == "2.5")
    #expect(transfer.display?.usd == "2.50")
  }

  @Test("sol request posts to the sol query path and parses signatures")
  func solRequestAndParsing() async throws {
    let recorder = Recorder()
    let client = makeClient(
      responseBody: """
        {
          "transactions": [
            {
              "signature": "5sig",
              "block": {"number": "9", "hash": "bh", "timestamp": "2026-08-12T10:00:00Z"},
              "status": "FINALIZED",
              "origin": "TURNKEY",
              "feePayer": "FeePayer111",
              "signers": [{"address": "FeePayer111", "writable": true}],
              "transfers": []
            }
          ]
        }
        """,
      recorder: recorder
    )

    let response = try await client.listSolTransactionHistory(
      organizationId: "org-1",
      sessionPublicKey: "session-pub",
      address: "SolAddr",
      caip2: "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1",
      limit: 10
    )

    #expect(
      recorder.requests.first?.url?.absoluteString
        == "https://api.test/public/v1/query/list_sol_transaction_history"
    )
    let tx = try #require(response.transactions?.first)
    #expect(tx.signature == "5sig")
    #expect(tx.feePayer == "FeePayer111")
    #expect(tx.status == "FINALIZED")
  }

  @Test("non-2xx response throws TurnkeyHistoryError with the status code")
  func httpErrorThrows() async throws {
    let recorder = Recorder()
    let client = makeClient(
      status: 403,
      responseBody: #"{"code":7,"message":"transaction history feature is not enabled for organization org-1"}"#,
      recorder: recorder
    )

    do {
      _ = try await listEth(client)
      Issue.record("expected TurnkeyHistoryError")
    } catch let error as TurnkeyHistoryError {
      #expect(error.statusCode == 403)
      #expect(error.body.contains("not enabled"))
    }
  }

  @Test("malformed response body throws rather than returning empty history")
  func malformedBodyThrows() async throws {
    let recorder = Recorder()
    let client = makeClient(responseBody: "not json", recorder: recorder)

    await #expect(throws: (any Error).self) {
      _ = try await listEth(client)
    }
  }

  @Test("missing transactions field decodes without throwing")
  func missingTransactionsField() async throws {
    let recorder = Recorder()
    let client = makeClient(responseBody: "{}", recorder: recorder)

    let response = try await listEth(client)
    #expect(response.transactions == nil)
  }
}
