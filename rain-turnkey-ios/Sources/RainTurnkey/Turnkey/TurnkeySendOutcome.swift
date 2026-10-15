import Foundation
import TurnkeyHttp
import TurnkeySwift
import TurnkeyTypes
@_spi(RainAdapter) import RainCore

// MARK: - Why this exists
//
// The vendor's typed send calls (`ethSendTransaction` / `solSendTransaction`, swift-sdk 4.0.0)
// submit the activity and then poll it inside the call (`ActivityPollerConfig`, default 1 s x 3).
// Their response types carry a NON-optional `sendTransactionStatusId` that only exists once the
// activity is COMPLETED: for every other ending — still PENDING when the poll gives up, FAILED,
// REJECTED, CONSENSUS_NEEDED — the vendor decodes the raw activity "as-is" into that type, the
// key is missing, and `JSONDecoder` throws. The `v1Activity` (with its id) is in the bytes and
// never reaches us. Left alone, every slow sponsored send looks like a generic failure with
// nothing to resume from — which invites a second send. And because the vendor's poll runs
// inside the same call, a 401 from it is indistinguishable from a 401 on the submit, so a plain
// refresh-and-retry would re-run the submit after Turnkey already accepted it.
//
// So the adapter owns the ending. Every send has exactly four:
//   1. a status id          -> the existing send-status poll (hash / signature / revert),
//   2. an accepted activity  -> waited on by id and classified (`awaitSendActivity`),
//   3. a refusal             -> left as itself (nothing was executed; a 401 there is not retried
//                               for sends — see `sortedSendOutcome`),
//   4. unknown fate          -> `RainError.transactionOutcomeUnknown` (RAIN_305), never a resend.
// Mirrors rain-sdk-android's `sendOutcome` (WALL-98/119); Android gets the activity from the
// Kotlin client's typed error at http 2.2.0, iOS reads it back from the activity log because the
// Swift client throws it away. See TURNKEY_SUPPORT.md "After a send is accepted".

/// How a Turnkey send ended at the vendor boundary.
internal enum TurnkeySendOutcome {
  /// The activity COMPLETED inside the vendor's poll and carries a send-status id.
  case statusId(String)
  /// Turnkey accepted the activity but the vendor could not return it; read back by id.
  case activity(v1Activity)
  /// The vendor lost the activity after the submit may have gone out; no identifier to resume.
  case dropped(Error)
}

/// Which send activity type a read-back looks for.
internal enum TurnkeySendKind: Sendable {
  case evm
  case solana

  var activityType: v1ActivityType {
    switch self {
    case .evm: .activity_type_eth_send_transaction
    case .solana: .activity_type_sol_send_transaction
    }
  }

  var noun: String {
    switch self {
    case .evm: "transaction"
    case .solana: "Solana transaction"
    }
  }
}

/// A send activity Turnkey settled as FAILED or REJECTED. Maps to `providerError` (RAIN_501) —
/// "settled, nothing moved" — never to `userRejected`, which is reserved for a user cancelling in
/// a wallet UI.
internal struct TurnkeySendActivityFailure: LocalizedError, Equatable {
  let activityId: String
  let status: v1ActivityStatus
  let reason: String?

  var errorDescription: String? {
    let what = status == .activity_status_rejected ? "rejected" : "failed"
    let detail = reason.map { ": \($0)" } ?? ""
    return "Turnkey \(what) the send (activity \(activityId))\(detail)"
  }
}

extension TurnkeyWalletProviderAdapter {
  /// Read-back window: activities created this long before the submit still count, so a clock
  /// skew between device and backend cannot hide the one we just made.
  private static let readBackSkew: TimeInterval = 30
  private static let readBackLimit = 20
  /// Reads by activity id after the vendor's own poll gave up; with the default interval that is
  /// ten more seconds, matching Android.
  internal static let activityWaitReads = 10

  // MARK: Sorting the vendor's ending

  /// Runs `submit` (the vendor's typed send call, returning its status id) and sorts how it
  /// ended. Throws only for endings that leave the send as itself — a refusal of the submit
  /// below 500 other than 401, or a `RainError` raised before anything was sent; everything else
  /// is an outcome, so the session coordinator never sees a post-submit failure it could retry.
  ///
  /// A 401, 408 or 429 is NOT left as itself for sends: the vendor polls inside the call with
  /// the same request path as the submit, so any of them may have come from a poll after the
  /// submit went through (the Swift client throws the identical `apiError` for both phases).
  /// They are handled like a decode failure — read the activity back (the read refreshes the
  /// session) — and end unknown if nothing is found. Losing one legitimate refresh-and-retry is
  /// cheaper than a duplicate transfer.
  ///
  /// Cancellation passes through untouched: a host cancelling a send must see
  /// `CancellationError`, not an outcome. A cancelled URLSession call surfaces as a URL error,
  /// so the task flag is checked too.
  internal func sortedSendOutcome(
    kind: TurnkeySendKind,
    matches: @escaping @Sendable (v1Activity) -> Bool,
    submit: () async throws -> String
  ) async throws -> TurnkeySendOutcome {
    let submittedAt = Date()
    do {
      return .statusId(try await submit())
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RainError {
      // Raised by our own code before the vendor call (body building, nonce fetch).
      throw error
    } catch {
      if Task.isCancelled { throw CancellationError() }
      let status = Self.httpStatus(of: error)
      if Self.isActivityNotCompletedDecode(error) || Self.mayFollowAcceptance(status) {
        if let activity = try await readBackSendActivity(kind: kind, since: submittedAt, matches: matches) {
          return .activity(activity)
        }
        return .dropped(error)
      }
      if let status, status < 500 {
        // Turnkey refused the submit; nothing was executed.
        throw error
      }
      // 5xx, transport failure, undecodable answer: the request may have gone out.
      return .dropped(error)
    }
  }

  /// Statuses the vendor's in-call poll can raise after an accepted submit, which therefore
  /// cannot be read as a refusal of the submit.
  private static func mayFollowAcceptance(_ status: Int?) -> Bool {
    status == 401 || status == 408 || status == 429
  }

  /// The ending the vendor cannot represent: it decoded a non-COMPLETED activity into a response
  /// type whose status id is non-optional.
  internal static func isActivityNotCompletedDecode(_ error: Error) -> Bool {
    var current: Error = error
    for _ in 0..<8 {
      if current is DecodingError { return true }
      if let request = current as? TurnkeyRequestError {
        switch request {
        case .sdkError(let underlying), .unknown(let underlying):
          current = underlying
          continue
        default:
          return false
        }
      }
      return false
    }
    return false
  }

  /// HTTP status of a vendor API error, through the SDK's wrapper shapes.
  internal static func httpStatus(of error: Error) -> Int? {
    var current: Error = error
    for _ in 0..<8 {
      if let request = current as? TurnkeyRequestError {
        switch request {
        case .apiError(let status, _):
          return status
        case .sdkError(let underlying), .unknown(let underlying):
          current = underlying
          continue
        default:
          return nil
        }
      }
      return nil
    }
    return nil
  }

  // MARK: Read-back

  /// Finds the activity the vendor dropped: the newest send activity of `kind` created at or
  /// after the submit (less skew) whose intent matches what we sent. Nil when the log shows no
  /// such activity, or the read itself fails — the caller then reports an unknown fate. Only
  /// cancellation throws.
  private func readBackSendActivity(
    kind: TurnkeySendKind,
    since submittedAt: Date,
    matches: @escaping @Sendable (v1Activity) -> Bool
  ) async throws -> v1Activity? {
    let response: TGetActivitiesResponse
    do {
      response = try await sessions.executeRead { session, client in
        try await client.getActivities(
          TGetActivitiesBody(
            organizationId: session.organizationId,
            filterByType: [kind.activityType],
            paginationOptions: v1Pagination(limit: String(Self.readBackLimit))
          )
        )
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled { throw CancellationError() }
      RainLogger.warning("Rain SDK: Turnkey send read-back failed: \(error)")
      return nil
    }
    let floor = submittedAt.timeIntervalSince1970 - Self.readBackSkew
    return response.activities
      .filter { Self.createdAt($0) >= floor && matches($0) }
      .max { Self.createdAt($0) < Self.createdAt($1) }
  }

  private static func createdAt(_ activity: v1Activity) -> TimeInterval {
    let seconds = Double(activity.createdAt.seconds) ?? 0
    let nanos = Double(activity.createdAt.nanos) ?? 0
    return seconds + nanos / 1_000_000_000
  }

  // MARK: Waiting on an accepted activity

  /// Turns an accepted activity into a send-status id: polls `getActivity` until the activity
  /// settles. COMPLETED -> its status id; FAILED / REJECTED -> `providerError` with Turnkey's
  /// reason; still executing after the budget -> `transactionPending` carrying the ACTIVITY id
  /// (no call takes it, but it matches the history row). ANY failure of a read mid-wait — the
  /// session dying, a dropped connection, a 5xx past the coordinator's retries — also ends as
  /// pending with the activity id: the send was accepted, only our view of it stopped, and a
  /// `networkError` or `providerError` here would read as "failed" and invite a second send.
  /// Only cancellation passes through.
  internal func awaitSendActivity(
    _ accepted: v1Activity,
    kind: TurnkeySendKind
  ) async throws -> String {
    var activity = accepted
    for read in 0..<Self.activityWaitReads {
      if let statusId = Self.completedStatusId(of: activity, kind: kind) {
        return statusId
      }
      switch activity.status {
      case .activity_status_failed, .activity_status_rejected:
        throw RainError.providerError(
          underlying: TurnkeySendActivityFailure(
            activityId: activity.id,
            status: activity.status,
            reason: activity.failure?.message
          )
        )
      case .activity_status_completed:
        // Completed without a readable result: nothing to poll, the host resumes from history.
        throw RainError.transactionPending(statusId: activity.id)
      default:
        break
      }
      if read + 1 == Self.activityWaitReads { break }
      try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
      do {
        activity = try await sessions.executeRead { session, client in
          try await client.getActivity(
            TGetActivityBody(organizationId: session.organizationId, activityId: activity.id)
          )
        }.activity
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw RainError.transactionPending(statusId: activity.id)
      }
    }
    throw RainError.transactionPending(statusId: activity.id)
  }

  private static func completedStatusId(of activity: v1Activity, kind: TurnkeySendKind) -> String? {
    let id: String? = switch kind {
    case .evm: activity.result.ethSendTransactionResult?.sendTransactionStatusId
    case .solana: activity.result.solSendTransactionResult?.sendTransactionStatusId
    }
    guard let id, !id.isEmpty else { return nil }
    return id
  }

  // MARK: Resolving an outcome to a status id

  /// Collapses an outcome to the status id the send-status poll needs, or throws the final error.
  internal func resolveStatusId(
    from outcome: TurnkeySendOutcome,
    kind: TurnkeySendKind
  ) async throws -> String {
    switch outcome {
    case .statusId(let id):
      return id
    case .activity(let activity):
      return try await awaitSendActivity(activity, kind: kind)
    case .dropped(let failure):
      // No cause on purpose: a layer above must not read an HTTP status off it and retry.
      throw RainError.transactionOutcomeUnknown(
        details: "Turnkey did not return the \(kind.noun) send activity; "
          + "the send may still land (\(Self.vendorMessage(failure)))"
      )
    }
  }

  /// A short, safe rendering of a vendor failure for an error message: no response bodies.
  private static func vendorMessage(_ error: Error) -> String {
    if let status = httpStatus(of: error) { return "HTTP \(status)" }
    if isActivityNotCompletedDecode(error) { return "activity not completed within the vendor's poll" }
    let text = (error as NSError).domain == NSURLErrorDomain
      ? error.localizedDescription
      : String(describing: type(of: error))
    return String(text.prefix(120))
  }

  // MARK: Intent matching

  /// The intent of an EVM send we composed, for matching a read-back activity. Hex compares are
  /// case-insensitive; empty calldata and `0x` are the same thing. The nonce the body carries —
  /// the account nonce on a self-paid send, the gas-station nonce on a sponsored one — is part
  /// of the identity, so an earlier identical send inside the window cannot be mistaken for
  /// this one. (A sponsored body with no gas-station nonce lets Turnkey pick it server-side;
  /// that send is then identified by the rest, and by the send gate serialising submits.)
  internal static func evmIntentMatcher(_ body: TEthSendTransactionBody) -> @Sendable (v1Activity) -> Bool {
    let from = body.from.lowercased()
    let to = body.to.lowercased()
    let data = normalizedHex(body.data)
    let value = body.value
    let caip2 = body.caip2
    let nonce = body.nonce
    let gasStationNonce = body.gasStationNonce
    return { activity in
      guard let intent = activity.intent.ethSendTransactionIntent else { return false }
      return intent.caip2 == caip2
        && intent.from.lowercased() == from
        && intent.to.lowercased() == to
        && normalizedHex(intent.data) == data
        && (value == nil || intent.value == value)
        && (nonce == nil || intent.nonce == nonce)
        && (gasStationNonce == nil || intent.gasStationNonce == gasStationNonce)
    }
  }

  /// The intent of a Solana send we composed. Turnkey echoes the unsigned transaction as it was
  /// submitted, so the blob is the identity; signer and cluster guard against a stale match.
  internal static func solanaIntentMatcher(_ body: TSolSendTransactionBody) -> @Sendable (v1Activity) -> Bool {
    let signWith = body.signWith
    let caip2 = body.caip2
    let unsigned = body.unsignedTransaction.lowercased()
    return { activity in
      guard let intent = activity.intent.solSendTransactionIntent else { return false }
      return intent.caip2 == caip2
        && intent.signWith == signWith
        && intent.unsignedTransaction.lowercased() == unsigned
    }
  }

  private static func normalizedHex(_ value: String?) -> String {
    guard let value, !value.isEmpty, value != "0x" else { return "" }
    return value.lowercased()
  }
}

// MARK: - Send gate

/// Serialises the submit-and-identify phase of sends on one adapter. Two overlapping sends
/// could otherwise both read back "the newest matching activity" and claim the same one; with
/// the gate, a send's read-back runs before the next send submits. Only that phase is gated —
/// the 30 s status poll runs outside it, so a slow confirmation does not block the next send.
/// Plain FIFO: a waiter is resumed in order and is not cancellable while queued (the phase it
/// waits for is bounded by the vendor's poll plus the activity wait).
internal actor TurnkeySendGate {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

extension TurnkeyWalletProviderAdapter {
  /// Runs `phase` under the adapter's send gate, releasing on every exit.
  internal func gatedSend<T>(_ phase: () async throws -> T) async throws -> T {
    await sendGate.acquire()
    do {
      let result = try await phase()
      await sendGate.release()
      return result
    } catch {
      await sendGate.release()
      throw error
    }
  }
}
