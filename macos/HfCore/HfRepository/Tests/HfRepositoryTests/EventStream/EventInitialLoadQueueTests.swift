import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import os
import Testing

// MARK: - EventInitialLoadQueueTests

@Suite struct EventInitialLoadQueueTests {
    @Test func givenDelayedInitialLoads_whenMoreThanFourAreQueued_thenCompletionAdvancesOneAndCancellationSkipsQueuedWork() async {
        // given
        let queue = EventInitialLoadQueue()
        let reader = DelayedReader()
        let ids = (0 ..< 8).map { _ in UUID() }
        for id in ids { queue.submit(id: id) { reader.begin(id, completion: $0) } }
        await waitUntil { reader.started.count == 4 }
        #expect(reader.started == Array(ids.prefix(4)))
        #expect(reader.peak == 4)

        // when
        queue.cancel(ids[4])
        // A canceled running read remains blocked: completing a different reader opens one slot.
        queue.cancel(ids[1])
        reader.finish(ids[0])
        await waitUntil { reader.started.count == 5 }

        // then
        #expect(reader.started.last == ids[5])
        #expect(reader.peak == 4)
        // Running cancellation cannot free a slot while the delayed read is still executing.
        reader.finish(ids[1])
        await waitUntil { reader.started.count == 6 }
        #expect(reader.started.last == ids[6])
        #expect(reader.peak == 4)
        reader.finishAll()
        await waitUntil { reader.started.count == 7 }
        reader.finishAll()
        #expect(!reader.started.contains(ids[4]))
    }

    @Test func givenSharedQueuedPublicLeases_whenAnotherTaskIsReleased_thenOneSharedReadStartsAndReleasedTaskNeverReads() async {
        // given
        let harness = PublicEventFacadeHarness()
        let repository = harness.repository
        let firstBlocker = repository.acquire("blocker-one")
        let secondBlocker = repository.acquire("blocker-two")
        defer { firstBlocker.release(); secondBlocker.release() }
        await waitUntil { harness.reader.requests.count == 2 }
        let first = repository.acquire("shared")
        let second = repository.acquire("shared")
        defer { second.release() }
        first.release()
        let released = repository.acquire("released")
        released.release()
        #expect(repository.events(for: "shared").isEmpty)
        #expect(repository.history(for: "shared").isLoading)
        // when — only an actually completed public read releases its global permit.
        harness.reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        await waitUntil { harness.reader.requests.count == 3 }
        #expect(harness.reader.requests[2].taskID == "shared")
        harness.reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(1)], capture: "future_capture")))
        await waitUntil { repository.events(for: "shared").count == 1 }
        harness.reader.finish(1, .success(ObservationFixtures.page(capture: "future_capture")))
        // then
        #expect(repository.leasedTaskIDs == ["blocker-one", "blocker-two", "shared"])
        #expect(repository.events(for: "released").isEmpty)
        #expect(!harness.reader.requests.contains { $0.taskID == "released" })
        #expect(harness.reader.requests.filter { $0.taskID == "shared" }.count == 1)
        #expect(repository.observation(for: "shared").summary.counts == nil)
    }

    private final class DelayedReader: Sendable {
        private struct State: Sendable {
            var callbacks: [UUID: @Sendable () -> Void] = [:]
            var recorded: [UUID] = []
            var maximum = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        var started: [UUID] { state.withLock { $0.recorded } }
        var peak: Int { state.withLock { $0.maximum } }

        func begin(_ id: UUID, completion: @escaping @Sendable () -> Void) {
            state.withLock {
                $0.recorded.append(id)
                $0.callbacks[id] = completion
                $0.maximum = max($0.maximum, $0.callbacks.count)
            }
        }

        func finish(_ id: UUID) {
            let completion = state.withLock { $0.callbacks.removeValue(forKey: id) }
            completion?()
        }

        func finishAll() {
            let completions = state.withLock {
                let values = Array($0.callbacks.values)
                $0.callbacks.removeAll()
                return values
            }
            for completion in completions { completion() }
        }
    }
}
