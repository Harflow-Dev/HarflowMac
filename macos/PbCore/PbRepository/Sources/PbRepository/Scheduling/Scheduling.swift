import Combine
import Foundation
import Mockable
import SwiftEnvironment

// MARK: - Scheduling

/// The one scheduling seam every production timer in this package goes through: the 1 s FSEvents
/// throttle and the 10 s safety poll (`TaskListRepository`). Tests inject a `MockScheduling` that
/// captures the scheduled closure and invokes it directly, so timing-dependent behaviour is driven
/// without ever sleeping.
@Mockable
public protocol Scheduling: Sendable {

    /// The current time. Routed through the seam so a test can control what "now" means for the
    /// reconcile-interval check without waiting for it.
    func now() -> Date

    /// Schedules `work` to run once, after `interval` seconds. Cancelling the returned token before
    /// it fires prevents `work` from running.
    @discardableResult
    func schedule(after interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable

    /// Schedules `work` to run every `interval` seconds, starting after the first interval elapses.
    /// Cancelling the returned token stops further firings.
    @discardableResult
    func scheduleRepeating(every interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable
}

// MARK: - NullScheduling

/// A `@GlobalEntry` default that never fires anything — safe to resolve before `Module` registers
/// the real `SystemScheduler`, and never itself calls a `@MainActor` initialiser.
public struct NullScheduling: Scheduling {
    public init() {}
    public func now() -> Date { Date() }
    public func schedule(after _: TimeInterval, execute _: @escaping @Sendable () -> Void) -> AnyCancellable { AnyCancellable {} }
    public func scheduleRepeating(every _: TimeInterval, execute _: @escaping @Sendable () -> Void) -> AnyCancellable { AnyCancellable {} }
}

// MARK: - Awaited waits

public extension Scheduling {

    /// Suspends for `interval` seconds as measured through this seam — the awaited counterpart of
    /// `schedule(after:execute:)`, so a polling loop's cadence is testable the same way: a test
    /// captures the scheduled closure and fires it directly, with no real timer and no fixed sleep
    /// (`NullScheduling` never fires it, which is why timing tests must inject a capturing fake).
    /// Returns early with `CancellationError` when the surrounding task is cancelled, and cancels
    /// the scheduled token so a stopped poll never leaves a dangling timer.
    func wait(for interval: TimeInterval) async throws {
        let gate = PollWaitGate()
        gate.arm(schedule(after: interval) { gate.fire() })
        try await withTaskCancellationHandler {
            try await gate.awaitFire()
        } onCancel: {
            gate.cancel()
        }
    }

    /// Seconds from `now` to the next minute boundary — the alignment delay of a minute-aligned
    /// presentation tick's first one-shot. Never zero: a scheduler handed a zero delay could
    /// legitimately fire immediately, which would turn the aligning shot into a double tick.
    func minuteBoundaryDelay(after now: Date, calendar: Calendar = .current) -> TimeInterval {
        guard let boundary = calendar.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) else {
            return 60
        }
        return max(0.05, boundary.timeIntervalSince(now))
    }
}

/// One lock-guarded resume for `Scheduling.wait(for:)`: exactly one of the scheduled fire and the
/// task-cancellation path may resume the continuation, whichever lands first — the other becomes a
/// no-op, so a fire racing a cancel can never double-resume.
private final class PollWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var cancelled = false
    private var token: AnyCancellable?
    private var continuation: CheckedContinuation<Void, Error>?

    func arm(_ token: AnyCancellable) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    /// The scheduled tick landed. No-op if cancellation already ended the wait.
    func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard !fired, !cancelled else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    /// The waiting task was cancelled: cancel the scheduled token and end the wait with
    /// `CancellationError`. No-op if the tick already fired.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !fired, !cancelled else { return }
        cancelled = true
        token?.cancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func awaitFire() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else if fired {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global scheduling seam.
    @GlobalEntry var scheduling: any Scheduling = NullScheduling()
}
