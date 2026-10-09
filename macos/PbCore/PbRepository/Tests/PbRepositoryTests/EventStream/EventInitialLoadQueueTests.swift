import Combine
import Foundation
import Mockable
import os
@testable import PbRepository
import PbTestUtilities
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

    @Test func givenSharedQueuedLeases_whenAnotherTaskIsReleased_thenSharedStreamLoadsAndReleasedStreamStaysUnread() async throws {
        // given
        let queue = EventInitialLoadQueue()
        let reader = DelayedReader()
        let blockers = (0 ..< 4).map { _ in UUID() }
        for id in blockers { queue.submit(id: id) { reader.begin(id, completion: $0) } }
        await waitUntil { reader.started.count == 4 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PbInitialLoads-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = #"{"v":1,"seq":1,"kind":"assistant_text","text":"loaded"}"# + "\n"
        for id in ["shared", "released"] {
            try line.write(to: directory.appendingPathComponent("\(id).events.jsonl"), atomically: true, encoding: .utf8)
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(directory.path)
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        let repository = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: snapshots,
            scheduler: scheduler, initialLoads: queue)

        // when
        let first = repository.acquire("shared")
        let second = repository.acquire("shared")
        defer { second.release() }
        first.release()
        let released = repository.acquire("released")
        released.release()
        #expect(repository.events(for: "shared").isEmpty)
        #expect(repository.history(for: "shared").isLoading)
        reader.finishAll()
        await waitUntil { !repository.history(for: "shared").isLoading && repository.summary(for: "shared").availability == .available }

        // then
        #expect(repository.events(for: "shared").count == 1)
        #expect(repository.leasedTaskIDs == ["shared"])
        #expect(repository.events(for: "released").isEmpty)
        // Exercise release/reacquire races with pending or already-running seed callbacks.
        second.release()
        for _ in 0 ..< 40 {
            let transient = repository.acquire("shared")
            transient.release()
            await Task.yield()
        }
        let final = repository.acquire("shared")
        defer { final.release() }
        await waitUntil { !repository.history(for: "shared").isLoading && repository.summary(for: "shared").availability == .available }
        #expect(repository.events(for: "shared").count == 1)
        #expect(!repository.history(for: "shared").isLoading)
        #expect(repository.summary(for: "shared").availability == .available)
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
