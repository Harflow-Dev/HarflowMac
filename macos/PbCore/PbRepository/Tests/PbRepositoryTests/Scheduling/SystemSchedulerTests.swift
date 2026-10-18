import Combine
import Foundation
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct SystemSchedulerTests {

    @Test func givenAScheduledOnceWork_whenTheIntervalElapses_thenItRuns() async {
        // given
        let sut = SystemScheduler()
        let box = LockedFlag()

        // when
        let token = sut.schedule(after: 0.01) { box.set() }

        // then
        await waitUntil(timeout: 2) { box.value }
        withExtendedLifetime(token) {}
    }

    @Test func givenAScheduledOnceWork_whenCancelledBeforeItFires_thenItNeverRuns() async {
        // given
        let sut = SystemScheduler()
        let box = LockedFlag()
        let token = sut.schedule(after: 0.05) { box.set() }

        // when
        token.cancel()
        try? await Task.sleep(for: .milliseconds(150))

        // then
        #expect(box.value == false)
    }

    @Test func givenARepeatingSchedule_whenObserved_thenItFiresMoreThanOnce() async {
        // given
        let sut = SystemScheduler()
        let counter = LockedCounter()
        let token = sut.scheduleRepeating(every: 0.02) { counter.increment() }

        // when
        await waitUntil(timeout: 2) { counter.value >= 2 }

        // then
        #expect(counter.value >= 2)
        token.cancel()
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock(); _value = true; lock.unlock()
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock(); _value += 1; lock.unlock()
    }
}
