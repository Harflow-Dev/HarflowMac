import Foundation
import HfTestUtilities
@testable import HfUI
import Testing

// MARK: - IncidentPresentationClockTests

@MainActor @Suite struct IncidentPresentationClockTests {
    @Test func givenMountedClock_whenMountedAgain_thenSeedsOnceAndStartsOneWakeLoop() async {
        // given
        let wake = ControlledPresentationWake()
        let clock = IncidentPresentationClock(wake: { try await wake.wait() }, now: { Date(timeIntervalSince1970: 10) })
        var ticks: [(Date, Bool)] = []
        // when
        clock.mount { ticks.append(($0, $1)) }
        clock.mount { ticks.append(($0, $1)) }
        await waitUntil { wake.pendingCount == 1 }
        // then
        #expect(ticks.count == 1)
        #expect(ticks[0].0 == Date(timeIntervalSince1970: 10))
        #expect(ticks[0].1)
        #expect(wake.pendingCount == 1)
        clock.unmount()
        await waitUntil { wake.cancelledCount == 1 }
        wake.release(0)
        await waitUntil { wake.returnedCount == 1 }
    }

    @Test func givenMountedClock_whenWakeCompletes_thenTicksOnceAndSchedulesOneNextWake() async {
        // given
        let wake = ControlledPresentationWake()
        let clock = IncidentPresentationClock(wake: { try await wake.wait() }, now: { Date(timeIntervalSince1970: 20) })
        var ticks: [(Date, Bool)] = []
        clock.mount { ticks.append(($0, $1)) }
        await waitUntil { wake.pendingCount == 1 }
        // when
        wake.release(0)
        await waitUntil { ticks.count == 2 && wake.issuedCount == 2 && wake.pendingCount == 1 }
        // then
        #expect(ticks.map(\.1) == [true, false])
        #expect(ticks[1].0 == Date(timeIntervalSince1970: 20))
        clock.unmount()
        await waitUntil { wake.cancelledCount == 1 }
        wake.release(1)
        await waitUntil { wake.returnedCount == 2 }
    }

    @Test func givenWakeSuspendedAtDetach_whenRemountedAndStaleWakeReleased_thenOnlyCurrentGenerationTicks() async {
        // given
        let wake = ControlledPresentationWake()
        var instant = Date(timeIntervalSince1970: 30)
        let clock = IncidentPresentationClock(wake: { try await wake.wait() }, now: { instant })
        var ticks: [(Date, Bool)] = []
        clock.mount { ticks.append(($0, $1)) }
        await waitUntil { wake.pendingCount == 1 }
        // when
        clock.unmount()
        await waitUntil { wake.cancelledCount == 1 }
        instant = Date(timeIntervalSince1970: 40)
        clock.mount { ticks.append(($0, $1)) }
        await waitUntil { wake.pendingCount == 2 }
        wake.release(0)
        await waitUntil { wake.returnedCount == 1 }
        // then: releasing the old continuation cannot deliver a tick into the remounted clock.
        #expect(ticks.map(\.0) == [Date(timeIntervalSince1970: 30), Date(timeIntervalSince1970: 40)])
        wake.release(1)
        await waitUntil { ticks.count == 3 && wake.issuedCount == 3 && wake.pendingCount == 1 }
        #expect(ticks.map(\.0) == [Date(timeIntervalSince1970: 30), Date(timeIntervalSince1970: 40), Date(timeIntervalSince1970: 40)])
        #expect(ticks.map(\.1) == [true, true, false])
        clock.unmount()
        await waitUntil { wake.cancelledCount == 2 }
        wake.release(2)
        await waitUntil { wake.returnedCount == 3 }
        #expect(wake.pendingCount == 0)
    }

    @Test func givenWakeSuspendedAtUnmount_whenReleased_thenNoTickOrFollowupWakeOccurs() async {
        // given
        let wake = ControlledPresentationWake()
        let clock = IncidentPresentationClock(wake: { try await wake.wait() })
        var tickCount = 0
        clock.mount { _, _ in tickCount += 1 }
        await waitUntil { wake.pendingCount == 1 }
        // when
        clock.unmount()
        await waitUntil { wake.cancelledCount == 1 }
        wake.release(0)
        await waitUntil { wake.returnedCount == 1 }
        // then
        #expect(tickCount == 1)
        #expect(wake.pendingCount == 0)
    }
}

// MARK: - ControlledPresentationWake

@MainActor final class ControlledPresentationWake {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private let cancellations = PresentationWakeCounter()

    var pendingCount: Int { continuations.compactMap(\.self).count }
    var issuedCount: Int { continuations.count }
    var returnedCount = 0
    var cancelledCount: Int { cancellations.value }

    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuations.append($0) }
            returnedCount += 1
        } onCancel: {
            cancellations.increment()
        }
    }

    func release(_ index: Int) {
        guard let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume()
    }
}

// MARK: - PresentationWakeCounter

private final class PresentationWakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
