import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import os
import Testing

// MARK: - PublicEventObservationReviewRegressionTests

@Suite struct PublicEventObservationReviewRegressionTests {
    @Test func givenCancellationBeforeAdmissionEnqueues_whenSubmitReturns_thenPostRegistrationFenceRemovesQueuedWork() async {
        // given
        let reader = ObservationScriptReader()
        let budget = CancellationRaceAdmission()
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: budget, delivery: { $0() })
        budget.onSubmit = { sut.stop() }
        // when
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { budget.cancellations >= 2 }
        budget.onSubmit = nil
        // then
        #expect(sut.snapshot.stopped)
        #expect(budget.pendingCount == 0)
        #expect(reader.requests.isEmpty)
    }

    @Test func givenObservedTaskData_whenRuntimeFenced_thenNewEpochContainsNoOldTaskProjection() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "a", path: "a")], newer: "summary")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(newer: "summary")))
        await waitUntil { sut.snapshot.summaryPhase == .caughtUp }
        let before = sut.snapshot
        #expect(before.summary.counts?.edits == 1)
        // when
        sut.invalidateRuntime()
        // then
        let after = sut.snapshot
        #expect(after.sessionID == before.sessionID)
        #expect(after.epoch != before.epoch)
        #expect(after.stopped)
        #expect(after.activity.isEmpty)
        #expect(after.rawBytes == 0)
        #expect(after.lifecycle == nil)
        #expect(after.liveCursor == nil)
        #expect(after.olderCursor == nil)
        #expect(after.summaryDeliveryCursor == nil)
        #expect(after.summary.counts == nil)
        #expect(after.summary.files.isEmpty)
        #expect(!after.forwardDrained)
    }

    @Test func givenDrainedForwardFinal_whenPublicLogBecomesUnavailable_thenDrainEvidenceIsRevoked() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page(newer: "forward", capture: "future_capture")))
        await waitUntil { sut.snapshot.liveCursor == "forward" }
        sut.tick()
        await waitUntil { reader.requests.count == 2 }
        let finished = ObservationFixtures.record(9, "task_finished", ["status": .string("completed")])
        reader.finish(1, .success(ObservationFixtures.page([finished], newer: "final", final: 9)))
        await waitUntil { sut.snapshot.forwardDrained }
        // when
        sut.tick()
        await waitUntil { reader.requests.count == 3 }
        var raw = ObservationFixtures.page().raw
        raw["log"] = .object(["state": .string("unavailable"), "task_status": .string("completed"),
            "capture_state": .string("unavailable"), "output_drained": .bool(false), "final_seq": .null])
        raw["newer_cursor"] = .null
        guard let unavailable = TaskEventPage(raw: raw) else { Issue.record("Invalid unavailable fixture"); return }
        reader.finish(2, .success(unavailable))
        await waitUntil { sut.snapshot.lifecycle?.state == .unavailable }
        // then
        #expect(!sut.snapshot.forwardDrained)
        #expect(sut.snapshot.issues.contains(.unavailable))
        #expect(sut.snapshot.summary.counts == nil)
    }

    @Test func givenAdvancingEmptyLivePages_whenTwoForwardPagesFinish_thenDrainPausesUntilNextExternalTick() async {
        // given
        let reader = ObservationScriptReader()
        let deliveries = LockedBox(0)
        let sut = makeSession(reader, delivery: { callback in callback(); deliveries.mutate { $0 += 1 } })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page(newer: "one", more: true, capture: "future_capture")))
        await waitUntil { reader.requests.count == 2 }
        reader.finish(1, .success(ObservationFixtures.page(newer: "two", more: true)))
        await waitUntil { reader.requests.count == 3 }
        let before = deliveries.value
        // when
        reader.finish(2, .success(ObservationFixtures.page(newer: "three", more: true)))
        // Apply publishes, then the yielded idle pump publishes: this proves the drain boundary was reached.
        await waitUntil { deliveries.value >= before + 2 }
        // then
        #expect(reader.requests.count == 3)
        #expect(sut.snapshot.liveCursor == "three")
        #expect(sut.snapshot.hasPendingLive)
        sut.tick()
        await waitUntil { reader.requests.count == 4 }
        #expect(reader.requests[3].position == .cursor("three"))
        sut.stop()
        reader.finish(3, .success(ObservationFixtures.page(newer: "four", more: true)))
    }

    private func makeSession(_ reader: ObservationScriptReader,
                             delivery: @escaping PublicEventObservationSession.Delivery = { $0() }) -> PublicEventObservationSession {
        PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: delivery)
    }
}

// MARK: - CancellationRaceAdmission

private final class CancellationRaceAdmission: PublicEventObservationAdmission, Sendable {
    private struct State: Sendable {
        var pending: [UUID: @Sendable (@escaping @Sendable () -> Void) -> Void] = [:]
        var cancellations = 0
        var onSubmit: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var onSubmit: (@Sendable () -> Void)? {
        get { state.withLock { $0.onSubmit } }
        set { state.withLock { $0.onSubmit = newValue } }
    }

    var cancellations: Int { state.withLock { $0.cancellations } }
    var pendingCount: Int { state.withLock { $0.pending.count } }
    func submit(id: UUID, work: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        let hook = state.withLock { $0.onSubmit }
        hook?()
        // Deliberately enqueue after the cancellation callback, matching the asynchronous admission race.
        state.withLock { $0.pending[id] = work }
    }

    func cancel(_ id: UUID) {
        state.withLock { $0.cancellations += 1; $0.pending.removeValue(forKey: id) }
    }
}
