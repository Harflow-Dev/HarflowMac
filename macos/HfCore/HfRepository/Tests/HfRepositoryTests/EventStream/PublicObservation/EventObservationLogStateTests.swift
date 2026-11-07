import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - EventObservationLogStateTests

@Suite struct EventObservationLogStateTests {
    private static let mapping: [(TaskEventLog.State, EventLogState)] = [
        (.open, .open), (.settling, .settling), (.final, .final),
        (.incomplete, .incomplete), (.unknown, .unknown), (.unavailable, .unavailable)
    ]

    // MARK: - Projector

    @Test(arguments: mapping)
    func givenEachLogState_whenProjected_thenTheMatchingEventLogStateIsExposed(pair: (TaskEventLog.State, EventLogState)) {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.lifecycle = Self.log(pair.0)

        // when
        let frame = Self.project(snapshot)

        // then
        #expect(frame.logState == pair.1)
    }

    @Test func givenNoLifecycle_whenProjected_thenLogStateIsNil() {
        // given
        let snapshot = PublicEventObservationSnapshot(sessionID: UUID())

        // when
        let frame = Self.project(snapshot)

        // then
        #expect(frame.logState == nil)
    }

    @Test(arguments: [PublicEventObservationIssue.capacity, .nonprogress])
    func givenCapacityOrNonprogressIssue_whenProjected_thenLogStateIsWithheld(issue: PublicEventObservationIssue) {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.lifecycle = Self.log(.final)
        snapshot.issues.insert(issue)

        // when
        let frame = Self.project(snapshot)

        // then
        #expect(frame.logState == nil)
    }

    @Test func givenCapacityAndNonprogressTogether_whenProjected_thenLogStateIsWithheld() {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.lifecycle = Self.log(.settling)
        snapshot.issues = [.capacity, .nonprogress]

        // when
        let frame = Self.project(snapshot)

        // then
        #expect(frame.logState == nil)
    }

    @Test(arguments: [PublicEventObservationIssue.historicalLimit, .unavailable, .resetExhausted])
    func givenAnUnrelatedIssue_whenProjected_thenLogStateIsKept(issue: PublicEventObservationIssue) {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.lifecycle = Self.log(.open)
        snapshot.issues.insert(issue)

        // when
        let frame = Self.project(snapshot)

        // then
        #expect(frame.logState == .open)
    }

    @Test func givenAClearedLifecycleOnASnapshot_whenProjected_thenLogStateBecomesNil() {
        // given
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.lifecycle = Self.log(.final)
        #expect(Self.project(snapshot).logState == .final)

        // when
        snapshot.lifecycle = nil

        // then
        #expect(Self.project(snapshot).logState == nil)
    }

    @Test func givenAFrameInit_whenLogStateIsOmitted_thenItDefaultsToNil() {
        // given / when
        let frame = Self.emptyFrame()

        // then
        #expect(frame.logState == nil)
    }

    // MARK: - Holder

    @Test func givenALogStateOnlyChange_whenApplied_thenItReportsAChangeExactlyOnce() {
        // given
        let holder = PublicEventHolder(taskID: "task")
        let base = Self.emptyFrame(logState: .open)
        #expect(holder.apply(base))

        // when
        let changed = Self.emptyFrame(scope: base.scope, logState: .final)
        let first = holder.apply(changed)
        let second = holder.apply(changed)

        // then
        #expect(first)
        #expect(!second)
        #expect(holder.frame.logState == .final)
    }

    @Test func givenAnUnchangedPoll_whenAppliedWithANewRevision_thenNoChangeIsReported() {
        // given
        let holder = PublicEventHolder(taskID: "task")
        let base = Self.emptyFrame(logState: .settling)
        #expect(holder.apply(base))

        // when
        let repoll = Self.emptyFrame(scope: base.scope, revision: 5, logState: .settling)

        // then
        #expect(!holder.apply(repoll))
    }

    @Test func givenAKnownState_whenTheStateIsWithheld_thenTheChangeToNilIsReportedOnce() {
        // given
        let holder = PublicEventHolder(taskID: "task")
        let base = Self.emptyFrame(logState: .final)
        #expect(holder.apply(base))

        // when
        let withheld = Self.emptyFrame(scope: base.scope, logState: nil)

        // then
        #expect(holder.apply(withheld))
        #expect(!holder.apply(withheld))
        #expect(holder.frame.logState == nil)
    }

    @Test func givenAFrameWithNilLogStateAndANewScope_whenApplied_thenLogStateIsNil() {
        // given
        let holder = PublicEventHolder(taskID: "task")
        #expect(holder.apply(Self.emptyFrame(logState: .final)))

        // when
        let replaced = Self.emptyFrame(logState: nil)

        // then
        #expect(holder.apply(replaced))
        #expect(holder.frame.logState == nil)
    }

    @Test func givenAKnownLogState_whenReset_thenTheFrameLogStateIsNil() {
        // given
        let holder = PublicEventHolder(taskID: "task")
        #expect(holder.apply(Self.emptyFrame(logState: .final)))

        // when
        holder.reset()

        // then
        #expect(holder.frame.logState == nil)
    }

    @Test func givenAFreshHolder_whenRead_thenLogStateIsNil() {
        // given / when
        let holder = PublicEventHolder(taskID: "task")

        // then
        #expect(holder.frame.logState == nil)
        #expect(holder.frames.value.frame.logState == nil)
    }

    // MARK: - Session

    @Test func givenAnOpenPageAndACapacityRejectedFinalPage_whenProjected_thenLogStateIsNilUntilTheWindowIsRebased() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        let initial = (0 ..< 200).map { ObservationFixtures.record($0, "future_kind") }
        reader.finish(0, .success(ObservationFixtures.page(initial, older: "older-0", capture: "future_capture", state: .open)))
        await waitUntil { sut.snapshot.activity.count == 200 }
        #expect(Self.project(sut.snapshot).logState == .open)
        for index in 1 ... 9 {
            sut.requestOlder()
            await waitUntil { reader.requests.count > index }
            let records = (0 ..< 200).map { ObservationFixtures.record(index * 200 + $0, "future_kind") }
            reader.finish(index, .success(ObservationFixtures.page(records, older: "older-\(index)")))
            await waitUntil { sut.snapshot.activity.count == (index + 1) * 200 }
        }

        // when
        sut.tick()
        await waitUntil { reader.requests.count == 11 }
        reader.finish(10, .success(ObservationFixtures.page([ObservationFixtures.record(9999)], newer: "rejected", final: 9999, state: .final)))
        await waitUntil { sut.snapshot.issues.contains(.capacity) }

        // then
        #expect(sut.snapshot.lifecycle?.state == .open)
        #expect(Self.project(sut.snapshot).logState == nil)

        // when the window is rebased
        sut.adoptCurrentActivity()
        await waitUntil { reader.requests.count == 12 }

        // then the real replacement has cleared the lifecycle
        #expect(sut.snapshot.lifecycle == nil)
        #expect(!sut.snapshot.issues.contains(.capacity))
        #expect(Self.project(sut.snapshot).logState == nil)

        // when the new window reports a state
        reader.finish(11, .success(ObservationFixtures.page([ObservationFixtures.record(5)], newer: "fresh", final: 5, state: .final)))
        await waitUntil { sut.snapshot.lifecycle?.state == .final }

        // then
        #expect(Self.project(sut.snapshot).logState == .final)
    }

    @Test func givenAnOpenPageAndForwardNonprogressOnAFinalPage_whenProjected_thenLogStateIsNilUntilRetried() async {
        // given
        let reader = ObservationScriptReader()
        let sut = makeSession(reader)
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1, "future_kind")], newer: "same", more: true, state: .open)))
        await waitUntil { reader.requests.count == 2 }
        #expect(Self.project(sut.snapshot).logState == .open)

        // when
        reader.finish(1, .success(ObservationFixtures.page(newer: "same", more: true, final: 2, state: .final)))
        await waitUntil { sut.snapshot.issues.contains(.nonprogress) }

        // then
        #expect(sut.snapshot.lifecycle?.state == .open)
        #expect(Self.project(sut.snapshot).logState == nil)

        // when the retry clears the issue and a fresh page reports the state
        sut.retryObservation()
        await waitUntil { reader.requests.count == 3 }
        reader.finish(2, .success(ObservationFixtures.page(newer: "next", final: 2, state: .final)))
        await waitUntil { sut.snapshot.lifecycle?.state == .final }

        // then
        #expect(!sut.snapshot.issues.contains(.nonprogress))
        #expect(Self.project(sut.snapshot).logState == .final)
    }

    // MARK: - Helpers

    private static func project(_ snapshot: PublicEventObservationSnapshot) -> EventObservationFrame {
        EventObservationFrameProjector.project(taskID: "task", snapshot: snapshot)
    }

    private static func emptyFrame(scope: EventObservationScope? = nil, revision: Int = 0,
                                   logState: EventLogState? = nil) -> EventObservationFrame {
        EventObservationFrame(taskID: "task",
                              scope: scope ?? EventObservationScope(sessionID: UUID(), sourceID: UUID(), windowID: UUID()),
                              revision: revision, logState: logState)
    }

    private static func log(_ state: TaskEventLog.State) -> TaskEventLog {
        ObservationFixtures.page(state: state).log
    }

    private func makeSession(_ reader: ObservationScriptReader) -> PublicEventObservationSession {
        PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
    }
}
