import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - ChangesReadScript

/// A scripted `readChanges` for the view model. Calls are recorded with their fence, and an action can run while a call is in
/// flight, so its result can arrive after the view model has moved on.
final class ChangesReadScript: @unchecked Sendable {

    /// What one call answers.
    enum Reply {
        case snapshot(TaskChangesSnapshot)
        case failure(TaskChangesReadFailure.Outcome)
        /// A snapshot keyed with another generation than the one requested.
        case wrongKey(TaskChangesSnapshot)
    }

    struct Call {
        let key: TaskChangesKey
        let fence: @Sendable () -> Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var replies: [Int: Reply] = [:]
    private var actions: [Int: @MainActor @Sendable () -> Void] = [:]
    private var fallback: Reply

    init(_ fallback: Reply) { self.fallback = fallback }

    var calls: [Call] { lock.withLock { recorded } }
    var count: Int { lock.withLock { recorded.count } }

    /// Replaces the answer given to every call that has no answer of its own.
    func answerFromNowOn(_ reply: Reply) { lock.withLock { fallback = reply } }

    /// Answers call `index` (zero based) with `reply`.
    func answer(_ index: Int, _ reply: Reply) { lock.withLock { replies[index] = reply } }

    /// Runs `action` while call `index` is in flight, before it answers. The producer runs inline on the main actor, so the
    /// action may drive the view model, which is how a result arrives after the view model has moved on.
    func whileInFlight(_ index: Int, _ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { actions[index] = action } }

    func serve(_ key: TaskChangesKey, _ fence: @escaping @Sendable () -> Bool)
        -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        let (index, action) = lock.withLock { () -> (Int, (@MainActor @Sendable () -> Void)?) in
            let index = recorded.count
            recorded.append(Call(key: key, fence: fence))
            return (index, actions[index])
        }
        if let action { MainActor.assumeIsolated { action() } }
        let reply = lock.withLock { replies[index] ?? fallback }
        switch reply {
        case .snapshot(let snapshot): return .success(TaskChangesRead(key: key, value: snapshot))
        case .wrongKey(let snapshot):
            return .success(TaskChangesRead(key: TaskChangesKey(taskID: key.taskID, generation: key.generation + 100), value: snapshot))
        case .failure(let outcome): return .failure(TaskChangesReadFailure(key: key, outcome: outcome))
        }
    }
}

/// A flag set by an Observation callback.
final class ChangesObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: - Rig

@MainActor
extension TaskDetailVMTests {

    struct ChangesRig {
        let harness: SUT
        let scheduler: CapturingScheduler
        let script: ChangesReadScript
        var scenario: SummaryEntryScenario
        var sut: TaskDetailVM { harness.sut }
    }

    /// A shown task `t1` with the given status and log state, a scripted reader and a capturing scheduler, appeared and listed.
    func openChangesRig(
        status: String = "completed", logState: EventLogState? = .final, chrome: TaskDetailChrome = .standalone,
        reply: ChangesReadScript.Reply? = nil
    ) async throws -> ChangesRig {
        let scheduler = CapturingScheduler()
        let harness = makeSUT(taskID: SummaryEntryScenario.taskID, chrome: chrome, scheduler: scheduler)
        let script = ChangesReadScript(try reply ?? .snapshot(ChangesJSON.zeroRows()))
        given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
        var scenario = SummaryEntryScenario()
        scenario.taskStatus = status
        scenario.snapshotStatus = status
        scenario.logState = logState
        harness.detailBox.value = scenario.task
        harness.snapshotBox.value = scenario.snapshot
        harness.observationBox.value = scenario.frame
        harness.sut.didAppear()
        harness.tasksSubject.send([scenario.task])
        await waitUntil { harness.sut.task != nil && harness.sut.observationFrames[SummaryEntryScenario.taskID] != nil }
        return ChangesRig(harness: harness, scheduler: scheduler, script: script, scenario: scenario)
    }

    func publishChanges(_ scenario: SummaryEntryScenario, to rig: ChangesRig) {
        rig.harness.detailBox.value = scenario.task
        rig.harness.snapshotBox.value = scenario.snapshot
        rig.harness.observationBox.value = scenario.frame
        rig.harness.observationSubject.send(scenario.frame)
        rig.harness.snapshotsSubject.send([SummaryEntryScenario.taskID: scenario.snapshot ?? scenario.task])
        rig.harness.tasksSubject.send([scenario.task])
    }

    /// Waits long enough for an unwanted read to have started, then reports the call count.
    func quietCallCount(_ rig: ChangesRig, seconds: TimeInterval = 0.3) async -> Int {
        await waitUntil(timeout: seconds) { false }
        return rig.script.count
    }

    var settlingReply: ChangesReadScript.Reply {
        get throws { .snapshot(try ChangesJSON.pendingSettling()) }
    }
}

// MARK: - Demand and triggers

@MainActor
extension TaskDetailVMTests {

    @Test func givenAStandaloneTaskWithTheLogFinal_whenNothingOpensThePane_thenNothingIsRead() async throws {
        // given
        let rig = try await openChangesRig()
        defer { rig.sut.didDisappear() }

        // when / then
        #expect(await quietCallCount(rig) == 0)
        #expect(rig.sut.changesPresentation == .loading)
        #expect(rig.sut.changesTabCount == nil)
    }

    @Test func givenThePaneOpens_whenReported_thenOneListingReadStartsForTheShownMemberAndItsResultApplies() async throws {
        // given
        let rig = try await openChangesRig(reply: .snapshot(try ChangesJSON.availableListing()))
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount != nil }

        // then
        #expect(rig.script.count == 1)
        #expect(rig.script.calls[0].key.taskID == "t1")
        #expect(rig.sut.changesTabCount == 6)
        guard case .document = rig.sut.changesPresentation else { Issue.record("expected a document"); return }
        #expect(!rig.sut.changesCaptureSettling)
    }

    @Test func givenAnAppliedRead_whenThePaneClosesAndReopens_thenItDoesNotReadAgain() async throws {
        // given
        let rig = try await openChangesRig()
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount != nil }

        // when
        rig.sut.setChangesPaneOpen(false)
        rig.sut.setChangesPaneOpen(true)

        // then
        #expect(await quietCallCount(rig) == 1)
        #expect(rig.sut.changesTabCount == 0)
    }

    @Test func givenARunningTask_whenThePaneIsOpen_thenItReadsOnceAndWaitsForTheStatusTransition() async throws {
        // given
        let rig = try await openChangesRig(status: "running", logState: .open, reply: .snapshot(try ChangesJSON.pendingRunning()))
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesPresentation != .loading }

        // then: no cadence and no further read while it runs
        #expect(await quietCallCount(rig) == 1)
        #expect(rig.scheduler.oneShotIntervals.isEmpty)
        #expect(!rig.sut.changesCaptureSettling)

        // when: the task completes
        rig.script.answerFromNowOn(.snapshot(try ChangesJSON.availableListing()))
        var done = rig.scenario
        done.taskStatus = "completed"
        done.snapshotStatus = "completed"
        done.logState = .final
        publishChanges(done, to: rig)
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(rig.script.count == 2)
    }

    @Test func givenNoDemand_whenTheStatusTransitions_thenNothingReadsUntilTheNextDemandAndThenOnce() async throws {
        // given
        let rig = try await openChangesRig(status: "running", logState: .open)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(false)

        // when: the transition happens with the pane closed
        var done = rig.scenario
        done.taskStatus = "completed"
        done.snapshotStatus = "completed"
        done.logState = .final
        publishChanges(done, to: rig)
        await waitUntil { rig.sut.task?.status == .completed }

        // then
        #expect(await quietCallCount(rig) == 0)

        // when: the pane opens
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 0 }

        // then
        #expect(rig.script.count == 1)
    }

    @Test func givenAnOpenPane_whenTheStatusTransitions_thenItReadsAgain() async throws {
        // given
        let rig = try await openChangesRig(status: "running", logState: .open)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.script.count == 1 && rig.sut.changesTabCount == 0 }

        // when
        var done = rig.scenario
        done.taskStatus = "completed"
        done.snapshotStatus = "completed"
        done.logState = .final
        publishChanges(done, to: rig)
        await waitUntil { rig.script.count == 2 }

        // then
        #expect(rig.script.calls[1].key.generation > rig.script.calls[0].key.generation)
    }

    @Test func givenASettlingLog_whenTheTaskIsShownWithThePaneClosed_thenItReadsWithoutThePane() async throws {
        // given / when: the VM only sees a closed pane at overlay width, so closed and overlay are the same input
        let rig = try await openChangesRig(logState: .settling)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.script.count == 1 }

        // then
        #expect(rig.script.calls[0].key.taskID == "t1")
        await waitUntil { rig.sut.changesTabCount == 0 }
    }

    @Test func givenARunningTaskWithASettlingLog_whenShown_thenItDoesNotReadBecauseTheStatusIsNotTerminal() async throws {
        // given
        let rig = try await openChangesRig(status: "running", logState: .settling)
        defer { rig.sut.didDisappear() }

        // when / then
        #expect(await quietCallCount(rig) == 0)
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenAGroupOrEmbeddedMount_whenThePaneIsReportedOpenAndTheLogSettles_thenItNeverReads(chrome: TaskDetailChrome) async throws {
        // given
        let rig = try await openChangesRig(logState: .settling, chrome: chrome)
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        rig.sut.didTapRetryChanges()

        // then
        #expect(await quietCallCount(rig) == 0)
        #expect(rig.sut.changesPresentation == .loading)
    }
}
