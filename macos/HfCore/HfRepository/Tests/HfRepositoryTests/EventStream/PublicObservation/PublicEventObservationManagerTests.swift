@testable import HfRepository
import HfTestUtilities
import Testing

// MARK: - PublicEventObservationManagerTests

@Suite struct PublicEventObservationManagerTests {
    @Test func givenSharedTaskLeases_whenLastLeaseReleasedAndReacquired_thenOldReleaseCannotStopNewLifetime() async {
        // given
        let reader = ObservationScriptReader()
        let manager = PublicEventObservationManager(scheduler: NullScheduling(), delivery: { $0() })
        let first = manager.acquire(taskID: "task", reader: reader) { _ in }
        let second = manager.acquire(taskID: "task", reader: reader) { _ in }
        #expect(first.session.id == second.session.id)
        await waitUntil { reader.requests.count == 1 }
        // when
        first.release()
        #expect(!second.session.snapshot.stopped)
        second.release()
        let replacement = manager.acquire(taskID: "task", reader: reader) { _ in }
        defer { replacement.release() }
        first.release()
        second.release()
        // then
        #expect(replacement.session.id != first.session.id)
        #expect(first.session.snapshot.stopped)
        #expect(!replacement.session.snapshot.stopped)
        reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(capture: "future_capture")))
    }

    @Test func givenTwoRunningReadsAndThirdLease_whenRunningLeaseCancelled_thenPermitIsHeldUntilActualReturn() async {
        // given
        let reader = ObservationScriptReader()
        let manager = PublicEventObservationManager(scheduler: NullScheduling(), delivery: { $0() })
        let first = manager.acquire(taskID: "one", reader: reader) { _ in }
        let second = manager.acquire(taskID: "two", reader: reader) { _ in }
        await waitUntil { reader.requests.count == 2 }
        let third = manager.acquire(taskID: "three", reader: reader) { _ in }
        defer { first.release(); second.release(); third.release() }
        // when
        first.release()
        #expect(reader.requests.count == 2)
        let finished = reader.requests.firstIndex { $0.taskID == "one" } ?? 0
        reader.finish(finished, .success(ObservationFixtures.page(capture: "future_capture")))
        await waitUntil { reader.requests.count == 3 }
        // then
        #expect(reader.requests[2].taskID == "three")
        #expect(first.session.snapshot.activity.isEmpty)
        reader.finish(1 - finished, .success(ObservationFixtures.page(capture: "future_capture")))
        reader.finish(2, .success(ObservationFixtures.page(capture: "future_capture")))
    }

    @Test func givenRuntimeReplacement_whenOldLeaseReleases_thenNewSameTaskSessionSurvives() async {
        // given
        let reader = ObservationScriptReader()
        let manager = PublicEventObservationManager(scheduler: NullScheduling(), delivery: { $0() })
        let old = manager.acquire(taskID: "task", reader: reader) { _ in }
        await waitUntil { reader.requests.count == 1 }
        // when
        manager.invalidateRuntime()
        let replacement = manager.acquire(taskID: "task", reader: reader) { _ in }
        defer { replacement.release() }
        old.release()
        // then
        #expect(old.session.snapshot.stopped)
        #expect(!replacement.session.snapshot.stopped)
        #expect(!reader.requests[0].isCurrent())
        reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(capture: "future_capture")))
    }
}
