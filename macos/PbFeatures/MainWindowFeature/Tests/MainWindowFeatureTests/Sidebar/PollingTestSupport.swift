import Combine
import Foundation
import PbRepository

// MARK: - FakeMonitorVisibility

/// A hand-written `MonitorVisibility` fake (stateful: live publishers, waiting, setter history),
/// for the same reason `FakeMainWindowNavigationCoordinator` exists — the behaviour under test is
/// stateful, which a `Mockable` stub expresses awkwardly. Default state: window visible, popover
/// closed — the pre-B1 polling behaviour every existing test assumed.
final class FakeMonitorVisibility: MonitorVisibility, @unchecked Sendable {
    private let lock = NSLock()
    private let visibleSubject: CurrentValueSubject<Bool, Never>
    private let popoverSubject = CurrentValueSubject<Bool, Never>(false)
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var mainWindowVisibleWrites: [Bool] = []
    private(set) var popoverWrites: [Bool] = []

    init(mainWindowVisible: Bool = true) {
        self.visibleSubject = CurrentValueSubject(mainWindowVisible)
    }

    var mainWindowVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return visibleSubject.value
    }

    var menuBarPopoverOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return popoverSubject.value
    }

    func mainWindowVisiblePublisher() -> AnyPublisher<Bool, Never> {
        visibleSubject.removeDuplicates().eraseToAnyPublisher()
    }

    func menuBarPopoverOpenPublisher() -> AnyPublisher<Bool, Never> {
        popoverSubject.removeDuplicates().eraseToAnyPublisher()
    }

    func waitForMainWindowVisible() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !parkOrResume(continuation) { continuation.resume() }
        }
    }

    /// Parks the waiter unless the window is already visible; synchronous, so the lock is legal.
    private func parkOrResume(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if visibleSubject.value { return false }
        waiters.append(continuation)
        return true
    }

    func setMainWindowVisible(_ visible: Bool) {
        lock.lock()
        mainWindowVisibleWrites.append(visible)
        let waitersToResume = visibleSubject.value != visible ? waiters : []
        if visibleSubject.value != visible { waiters = [] }
        visibleSubject.send(visible)
        lock.unlock()
        for waiter in waitersToResume { waiter.resume() }
    }

    func setMenuBarPopoverOpen(_ open: Bool) {
        lock.lock()
        popoverWrites.append(open)
        popoverSubject.send(open)
        lock.unlock()
    }
}

// MARK: - CapturingScheduler

/// A `Scheduling` fake that records every scheduled closure instead of running it, so a test
/// drives cadence by firing the captured closures directly — never a real timer, never a fixed
/// sleep, and never `NullScheduling` (whose `schedule(after:)` never fires, making any
/// "it did not poll again" assertion vacuous).
final class CapturingScheduler: Scheduling, @unchecked Sendable {
    struct OneShot { let interval: TimeInterval; let work: @Sendable () -> Void }
    struct Repeat { let interval: TimeInterval; let work: @Sendable () -> Void }

    private let lock = NSLock()
    private var nowValue: Date
    private(set) var oneShots: [OneShot] = []
    private(set) var repeats: [Repeat] = []

    init(now: Date = Date(timeIntervalSince1970: 1_758_000_000)) {
        self.nowValue = now
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return nowValue
    }

    func advance(to date: Date) {
        lock.lock(); defer { lock.unlock() }
        nowValue = date
    }

    func schedule(after interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable {
        lock.lock(); defer { lock.unlock() }
        oneShots.append(OneShot(interval: interval, work: work))
        return AnyCancellable {}
    }

    func scheduleRepeating(every interval: TimeInterval, execute work: @escaping @Sendable () -> Void) -> AnyCancellable {
        lock.lock(); defer { lock.unlock() }
        repeats.append(Repeat(interval: interval, work: work))
        return AnyCancellable {}
    }

    /// Fires and removes the first captured one-shot.
    func fireFirstOneShot() {
        let work: (@Sendable () -> Void)?
        lock.lock()
        if !oneShots.isEmpty { work = oneShots.removeFirst().work } else { work = nil }
        lock.unlock()
        work?()
    }

    /// Number of captured, not-yet-fired one-shots scheduled for exactly `interval` seconds.
    func oneShotCount(interval: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        return oneShots.filter { $0.interval == interval }.count
    }

    /// Delays of every captured, not-yet-fired one-shot, in scheduling order.
    var oneShotIntervals: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return oneShots.map(\.interval)
    }

    /// Fires and removes the first captured one-shot scheduled for exactly `interval` seconds.
    @discardableResult
    func fireOneShot(interval: TimeInterval) -> Bool {
        let work: (@Sendable () -> Void)?
        lock.lock()
        if let index = oneShots.firstIndex(where: { $0.interval == interval }) {
            work = oneShots.remove(at: index).work
        } else { work = nil }
        lock.unlock()
        work?()
        return work != nil
    }

    /// Intervals of every captured repeating schedule.
    var repeatIntervals: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return repeats.map(\.interval)
    }

    /// Fires the first captured repeat, however many times the test wants a period to pass.
    func fireFirstRepeat(times: Int = 1) {
        let work: (@Sendable () -> Void)?
        lock.lock()
        if !repeats.isEmpty { work = repeats[0].work } else { work = nil }
        lock.unlock()
        for _ in 0 ..< times { work?() }
    }
}

// MARK: - PollCounter

/// A lock-protected counter for `@Sendable` test closures (a presentation-build counter, a
/// request counter) — `Box` types in the suites are not `Sendable`.
final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
