import Testing
import Foundation
import TurnkeyHttp
import TurnkeySwift
import TurnkeyTypes
@_spi(RainAdapter) @testable import RainCore
@testable import RainTurnkey

/// How a Turnkey send ends after the submit. The vendor's typed send call (swift-sdk 4.0.0) only
/// decodes a COMPLETED activity; every other ending throws a `DecodingError` that loses the
/// activity, so the adapter reads it back from the activity log and waits on it by id. These
/// pin the four endings — status id, accepted activity, refusal, unknown fate — on both chains,
/// and that a send is never submitted twice. Mirrors rain-sdk-android's send-outcome tests.
@Suite("Turnkey Send Outcome Tests")
struct TurnkeySendOutcomeTests {
  private static let caip2 = "eip155:1"
  private static let from = MockTurnkey.defaultWalletAddress
  private static let to = TestFixtures.recipientAddress

  private func makeAdapter(_ turnkey: MockTurnkey) -> TurnkeyWalletProviderAdapter {
    // Sponsored: the body needs no JSON-RPC quotes, only the mock's gas-station nonce.
    let adapter = TurnkeyWalletProviderAdapter(
      turnkey: turnkey,
      networkConfigs: TestFixtures.configs(),
      sponsorGas: true,
      chainReader: MockChainReader()
    )
    adapter.pollingIntervalNanoseconds = 1
    return adapter
  }

  private func send(_ adapter: TurnkeyWalletProviderAdapter) async throws -> String {
    try await adapter.sendTransaction(
      chainId: 1,
      params: WalletTransactionParams(from: Self.from, to: Self.to, value: "0x1", data: "0x")
    )
  }

  /// An EVM send activity matching what `send` submits, in the given state. Carries the
  /// gas-station nonce the sponsored body fetches (the mock's default), since the matcher
  /// compares it.
  private func activity(
    id: String = "activity-1",
    status: v1ActivityStatus,
    statusId: String? = nil,
    failure: String? = nil,
    createdAtSeconds: String = String(Int(Date().timeIntervalSince1970)),
    gasStationNonce: String? = "7"
  ) -> v1Activity {
    MockTurnkey.makeActivity(
      id: id, from: Self.from, to: Self.to, caip2: Self.caip2, value: "1", data: nil,
      sendTransactionStatusId: statusId, status: status, failureMessage: failure,
      createdAtSeconds: createdAtSeconds, gasStationNonce: gasStationNonce
    )
  }

  // MARK: - Pending after the vendor's poll

  @Test("a send still pending after the vendor's poll is read back and waited on to its status id")
  func pendingThenCompleted() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let pending = activity(status: .activity_status_pending)
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(pending, kind: .evm)
    client.mockActivities = [pending]
    client.activityByIdQueue = [
      pending,
      activity(status: .activity_status_completed, statusId: "late-status-id"),
    ]
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0xabc")]

    let hash = try await send(makeAdapter(turnkey))

    #expect(hash == "0xabc")
    #expect(client.ethSendTransactionCalls.count == 1, "never submitted twice")
    #expect(client.getActivitiesCalls.count == 1, "one read-back")
    #expect(client.getActivityCalls.map(\.activityId) == ["activity-1", "activity-1"])
    #expect(client.sendTransactionStatusCalls.map(\.sendTransactionStatusId) == ["late-status-id"])
  }

  @Test("a send pending for the whole wait is RAIN_302 carrying the activity id, not a failure")
  func pendingForTheWholeWait() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let pending = activity(status: .activity_status_pending)
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(pending, kind: .evm)
    client.mockActivities = [pending]
    client.activityByIdQueue = [pending]

    await #expect(throws: RainError.transactionPending(statusId: "activity-1")) {
      try await send(makeAdapter(turnkey))
    }
    #expect(client.ethSendTransactionCalls.count == 1)
    #expect(client.getActivityCalls.count == TurnkeyWalletProviderAdapter.activityWaitReads - 1)
    #expect(client.sendTransactionStatusCalls.isEmpty)
  }

  // MARK: - Settled failures

  @Test("a REJECTED activity is a providerError carrying Turnkey's reason, never userRejected")
  func rejectedWithReason() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let rejected = activity(status: .activity_status_rejected, failure: "policy denied the transfer")
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(rejected, kind: .evm)
    client.mockActivities = [rejected]

    do {
      _ = try await send(makeAdapter(turnkey))
      Issue.record("expected a providerError")
    } catch let error as RainError {
      guard case .providerError(let underlying) = error else {
        Issue.record("expected providerError, got \(error)")
        return
      }
      let failure = try #require(underlying as? TurnkeySendActivityFailure)
      #expect(failure.activityId == "activity-1")
      #expect(failure.status == .activity_status_rejected)
      #expect(failure.reason == "policy denied the transfer")
      #expect(error.code == "RAIN_501")
    }
    #expect(client.ethSendTransactionCalls.count == 1)
    #expect(client.getActivityCalls.isEmpty, "a settled activity is not polled")
  }

  @Test("a FAILED activity reached while waiting ends the wait as a providerError")
  func failedWhileWaiting() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let pending = activity(status: .activity_status_pending)
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(pending, kind: .evm)
    client.mockActivities = [pending]
    client.activityByIdQueue = [activity(status: .activity_status_failed, failure: "nonce too low")]

    do {
      _ = try await send(makeAdapter(turnkey))
      Issue.record("expected a providerError")
    } catch let error as RainError {
      guard case .providerError(let underlying) = error,
            let failure = underlying as? TurnkeySendActivityFailure
      else {
        Issue.record("expected providerError, got \(error)")
        return
      }
      #expect(failure.reason == "nonce too low")
    }
  }

  // MARK: - Unknown fate

  @Test("a 5xx on the submit is RAIN_305 with no cause and no second submit")
  func serverErrorOnSubmit() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = TurnkeyRequestError.apiError(
      statusCode: 502, payload: Data("<html>bad gateway</html>".utf8)
    )

    do {
      _ = try await send(makeAdapter(turnkey))
      Issue.record("expected transactionOutcomeUnknown")
    } catch let error as RainError {
      guard case .transactionOutcomeUnknown(let details) = error else {
        Issue.record("expected transactionOutcomeUnknown, got \(error)")
        return
      }
      #expect(error.code == "RAIN_305")
      #expect(details.contains("HTTP 502"))
      #expect(!details.contains("bad gateway"), "response bodies stay out of the message")
    }
    #expect(client.ethSendTransactionCalls.count == 1)
    #expect(client.getActivitiesCalls.isEmpty, "a 5xx is not an accepted activity; nothing to read back")
  }

  @Test("a transport failure after the submit is RAIN_305, not networkError")
  func transportFailure() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = URLError(.networkConnectionLost)

    await #expect(throws: RainError.transactionOutcomeUnknown(details: "")) {
      try await send(makeAdapter(turnkey))
    }
    #expect(client.ethSendTransactionCalls.count == 1)
  }

  @Test("a non-completed activity the read-back cannot find is RAIN_305")
  func readBackFindsNothing() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let pending = activity(status: .activity_status_pending)
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(pending, kind: .evm)
    // The log only shows an OLD send to the same recipient — outside the window, so not ours.
    client.mockActivities = [activity(id: "stale", status: .activity_status_pending, createdAtSeconds: "1714521600")]

    await #expect(throws: RainError.transactionOutcomeUnknown(details: "")) {
      try await send(makeAdapter(turnkey))
    }
    #expect(client.getActivitiesCalls.count == 1)
    #expect(client.getActivityCalls.isEmpty)
  }

  @Test("the read-back picks the newest matching activity, not one for another recipient")
  func readBackMatchesIntent() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let ours = activity(id: "ours", status: .activity_status_completed, statusId: "ours-status")
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(
      activity(id: "ours", status: .activity_status_pending), kind: .evm
    )
    let other = MockTurnkey.makeActivity(
      id: "other", from: Self.from, to: "0x" + String(repeating: "9", count: 40),
      caip2: Self.caip2, value: "1", data: nil, sendTransactionStatusId: "other-status",
      createdAtSeconds: String(Int(Date().timeIntervalSince1970) + 1)
    )
    client.mockActivities = [other, ours]
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0xours")]

    let hash = try await send(makeAdapter(turnkey))

    #expect(hash == "0xours")
    #expect(client.sendTransactionStatusCalls.map(\.sendTransactionStatusId) == ["ours-status"])
  }

  // MARK: - 401 around the submit

  @Test("a 401 from the send call is never retried as a second submit; the activity is read back")
  func unauthorizedAroundSubmitReadsBack() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    client.mockActivities = [activity(status: .activity_status_completed, statusId: "recovered")]
    client.sendTransactionStatusQueue = [.broadcasted(hash: "0xrecovered")]

    let hash = try await send(makeAdapter(turnkey))

    #expect(hash == "0xrecovered")
    #expect(client.ethSendTransactionCalls.count == 1, "the submit may have gone through; no re-run")
  }

  @Test("a 401 with nothing in the activity log is RAIN_305, not a second submit")
  func unauthorizedWithNothingToReadBack() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)

    await #expect(throws: RainError.transactionOutcomeUnknown(details: "")) {
      try await send(makeAdapter(turnkey))
    }
    #expect(client.ethSendTransactionCalls.count == 1)
  }

  // MARK: - Refusals

  @Test("a 4xx refusal of the submit leaves as a settled error with nothing to read back")
  func refusalLeavesAsItself() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = TurnkeyRequestError.apiError(statusCode: 403, payload: nil)

    // The adapter rethrows the vendor's refusal as-is; the manager maps it at the boundary.
    do {
      _ = try await send(makeAdapter(turnkey))
      Issue.record("expected the refusal to propagate")
    } catch {
      #expect(RainError.from(underlying: error) == .unauthorized())
    }
    #expect(client.ethSendTransactionCalls.count == 1)
    #expect(client.getActivitiesCalls.isEmpty)
  }

  // MARK: - Session dying mid-wait

  @Test("a session dying while waiting on the activity ends as RAIN_302 with the activity id")
  func sessionDiesWhileWaiting() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let pending = activity(status: .activity_status_pending)
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(pending, kind: .evm)
    client.mockActivities = [pending]
    client.getActivityError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)
    turnkey.refreshSessionError = TurnkeyRequestError.apiError(statusCode: 401, payload: nil)

    await #expect(throws: RainError.transactionPending(statusId: "activity-1")) {
      try await send(makeAdapter(turnkey))
    }
  }

  // MARK: - Review follow-ups (#44)

  @Test("a 429 or 408 from the send call may be the vendor's poll, so the activity is read back")
  func rateLimitAfterAcceptanceReadsBack() async throws {
    for status in [429, 408] {
      let turnkey = MockTurnkey()
      let client = turnkey.turnkeyClient as! MockTurnkeyClient
      client.ethSendTransactionError = TurnkeyRequestError.apiError(statusCode: status, payload: nil)
      client.mockActivities = [activity(status: .activity_status_completed, statusId: "recovered")]
      client.sendTransactionStatusQueue = [.broadcasted(hash: "0xrecovered")]

      let hash = try await send(makeAdapter(turnkey))

      #expect(hash == "0xrecovered", "HTTP \(status)")
      #expect(client.ethSendTransactionCalls.count == 1, "HTTP \(status): no second submit")
    }
  }

  @Test("a 5xx while waiting on the activity ends as RAIN_302 with the activity id, not 501")
  func serverErrorWhileWaiting() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let pending = activity(status: .activity_status_pending)
    client.ethSendTransactionError = MockTurnkeyClient.activityNotCompletedError(pending, kind: .evm)
    client.mockActivities = [pending]
    client.getActivityError = TurnkeyRequestError.apiError(statusCode: 503, payload: nil)

    await #expect(throws: RainError.transactionPending(statusId: "activity-1")) {
      try await send(makeAdapter(turnkey))
    }
  }

  @Test("a failed status read after a status id ends as RAIN_302 with the status id, not 301/501")
  func statusReadFailureKeepsTheStatusId() async throws {
    for failure: Error in [URLError(.networkConnectionLost), TurnkeyRequestError.apiError(statusCode: 500, payload: nil)] {
      let turnkey = MockTurnkey()
      let client = turnkey.turnkeyClient as! MockTurnkeyClient
      client.sendTransactionStatusError = failure

      await #expect(throws: RainError.transactionPending(statusId: "send-status-id")) {
        try await send(makeAdapter(turnkey))
      }
      #expect(client.ethSendTransactionCalls.count == 1)
    }
  }

  @Test("a cancelled send surfaces as CancellationError, never as an outcome")
  func cancellationPassesThrough() async throws {
    let turnkey = MockTurnkey()
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    client.ethSendTransactionError = CancellationError()

    await #expect(throws: CancellationError.self) {
      try await send(makeAdapter(turnkey))
    }
    #expect(client.getActivitiesCalls.isEmpty)
  }

  @Test("the EVM matcher tells two otherwise identical sends apart by their nonce")
  func evmMatcherUsesNonce() {
    let body = TEthSendTransactionBody(
      organizationId: "org", caip2: Self.caip2, data: nil, from: Self.from,
      gasStationNonce: "7", sponsor: true, to: Self.to, value: "1"
    )
    let matches = TurnkeyWalletProviderAdapter.evmIntentMatcher(body)
    func withNonce(_ gasStationNonce: String?) -> v1Activity {
      MockTurnkey.makeActivity(
        id: "a", from: Self.from, to: Self.to, caip2: Self.caip2, value: "1", data: nil,
        sendTransactionStatusId: nil, status: .activity_status_pending, gasStationNonce: gasStationNonce
      )
    }
    #expect(matches(withNonce("7")))
    #expect(!matches(withNonce("6")), "an earlier identical send carries an earlier nonce")
  }

  @Test("the send gate runs submit phases one at a time, in order")
  func sendGateSerialises() async throws {
    let gate = TurnkeySendGate()
    let log = Log()

    await gate.acquire()
    let second = Task {
      await gate.acquire()
      await log.append("second-in")
      await gate.release()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    await log.append("first-done")
    await gate.release()
    await second.value

    #expect(await log.entries == ["first-done", "second-in"])
  }

  private actor Log {
    var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
  }

  // MARK: - Classification helpers

  @Test("the vendor's not-completed decode failure is recognised through its wrapper shapes")
  func recognisesDecodeFailure() {
    let raw = MockTurnkeyClient.activityNotCompletedError(activity(status: .activity_status_pending), kind: .evm)
    #expect(TurnkeyWalletProviderAdapter.isActivityNotCompletedDecode(raw))
    #expect(TurnkeyWalletProviderAdapter.isActivityNotCompletedDecode(TurnkeyRequestError.unknown(raw)))
    #expect(!TurnkeyWalletProviderAdapter.isActivityNotCompletedDecode(URLError(.timedOut)))
    #expect(!TurnkeyWalletProviderAdapter.isActivityNotCompletedDecode(
      TurnkeyRequestError.apiError(statusCode: 500, payload: nil)
    ))
  }

  @Test("the Solana matcher keys on the unsigned transaction, signer and cluster")
  func solanaMatcher() {
    let body = TSolSendTransactionBody(
      organizationId: "org", caip2: "solana:devnet", recentBlockhash: nil,
      signWith: "signer", sponsor: true, unsignedTransaction: "ABCDEF"
    )
    let matches = TurnkeyWalletProviderAdapter.solanaIntentMatcher(body)
    let same = MockTurnkey.makeSolanaActivity(
      id: "a", signWith: "signer", caip2: "solana:devnet", unsignedTransaction: "abcdef", sendTransactionStatusId: nil
    )
    let otherSigner = MockTurnkey.makeSolanaActivity(
      id: "b", signWith: "someone", caip2: "solana:devnet", unsignedTransaction: "abcdef", sendTransactionStatusId: nil
    )
    let otherTx = MockTurnkey.makeSolanaActivity(
      id: "c", signWith: "signer", caip2: "solana:devnet", unsignedTransaction: "000000", sendTransactionStatusId: nil
    )
    #expect(matches(same))
    #expect(!matches(otherSigner))
    #expect(!matches(otherTx))
  }

  @Test("the Solana funnel sorts outcomes the same way: pending is read back and waited on")
  func solanaPendingWaitedOn() async throws {
    let turnkey = MockTurnkey(wallets: [MockTurnkey.dualCurveWallet()])
    let client = turnkey.turnkeyClient as! MockTurnkeyClient
    let adapter = makeAdapter(turnkey)
    let body = TSolSendTransactionBody(
      organizationId: "org", caip2: "solana:devnet", recentBlockhash: nil,
      signWith: MockTurnkey.defaultSolanaAddress, sponsor: true, unsignedTransaction: "ABCDEF"
    )
    let pending = MockTurnkey.makeSolanaActivity(
      id: "sol-1", signWith: body.signWith, caip2: body.caip2, unsignedTransaction: body.unsignedTransaction,
      sendTransactionStatusId: nil, createdAtSeconds: String(Int(Date().timeIntervalSince1970)),
      status: .activity_status_pending
    )
    client.mockActivities = [pending]
    client.activityByIdQueue = [
      MockTurnkey.makeSolanaActivity(
        id: "sol-1", signWith: body.signWith, caip2: body.caip2, unsignedTransaction: body.unsignedTransaction,
        sendTransactionStatusId: "sol-status"
      )
    ]

    let outcome = try await adapter.sortedSendOutcome(
      kind: .solana, matches: TurnkeyWalletProviderAdapter.solanaIntentMatcher(body)
    ) {
      throw MockTurnkeyClient.activityNotCompletedError(pending, kind: .solana)
    }
    guard case .activity(let found) = outcome else {
      Issue.record("expected an accepted activity, got \(outcome)")
      return
    }
    #expect(found.id == "sol-1")
    let statusId = try await adapter.resolveStatusId(from: outcome, kind: .solana)
    #expect(statusId == "sol-status")
  }
}
