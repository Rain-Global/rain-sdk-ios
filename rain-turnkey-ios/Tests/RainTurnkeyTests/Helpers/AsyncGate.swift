import Foundation

/// Cross-suite mutual exclusion that suspends instead of blocking a thread. A `DispatchSemaphore`
/// parks cooperative-pool threads; on a 3-core CI runner three parked waiters deadlock the process.
final class AsyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    let acquired: Bool = lock.withLock {
      if held { return false }
      held = true
      return true
    }
    if acquired { return }
    await withCheckedContinuation { continuation in
      let acquiredNow: Bool = lock.withLock {
        if held {
          waiters.append(continuation)
          return false
        }
        held = true
        return true
      }
      if acquiredNow { continuation.resume() }
    }
  }

  /// Hands the gate straight to the next waiter (FIFO), so a release never races a fresh acquire.
  func release() {
    let next: CheckedContinuation<Void, Never>? = lock.withLock {
      guard !waiters.isEmpty else {
        held = false
        return nil
      }
      return waiters.removeFirst()
    }
    next?.resume()
  }
}
