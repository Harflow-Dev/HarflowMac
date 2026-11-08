import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - Fencing, teardown, retry and failures

@MainActor
extension TaskDetailVMTests {

    @Test func givenASecondRead_whenItStarts_thenTheFirstFenceIsStaleAndTheSecondIsCurrent() async throws {
        // given
        let rig = try await openChangesRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.scheduler.oneShotIntervals == [5] }

        // when
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.script.count == 2 }

        // then
        let calls = rig.script.calls
        #expect(!calls[0].fence())
        #expect(calls[1].fence())
    }

    @Test func givenAReadInFlight_whenANewEpochStartsBeforeItAnswers_thenTheLateResultNeverApplies() async throws {
        // given: the first read answers with a listing after Retry has started a newer read, which itself answers with a dropped key
        let rig = try await openChangesRig(reply: .wrongKey(try ChangesJSON.zeroRows()))
        defer { rig.sut.didDisappear() }
        let sut = rig.sut
        rig.script.answer(0, .snapshot(try ChangesJSON.availableListing()))
        rig.script.whileInFlight(0) { sut.didTapRetryChanges() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.script.count == 2 }
        await waitUntil(timeout: 0.3) { rig.sut.changesTabCount != nil }

        // then: only the stale listing could have applied, and it is dropped
        #expect(rig.sut.changesTabCount == nil)
        #expect(rig.sut.changesPresentation == .loading)
        #expect(!rig.script.calls[0].fence())
        #expect(rig.script.calls[1].fence())
    }

    @Test func givenAResultKeyedWithAnotherGeneration_whenItArrives_thenItIsDropped() async throws {
        // given
        let rig = try await openChangesRig(reply: .wrongKey(try ChangesJSON.availableListing()))
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.script.count == 1 }
        await waitUntil(timeout: 0.3) { rig.sut.changesPresentation != .loading }

        // then
        #expect(rig.sut.changesPresentation == .loading)
        #expect(rig.sut.changesTabCount == nil)
    }

    @Test func givenAReadInFlight_whenTheViewDisappears_thenTheLateResultNeverAppliesAndTheFenceIsStale() async throws {
        // given
        let rig = try await openChangesRig(reply: .snapshot(try ChangesJSON.availableListing()))
        let sut = rig.sut
        rig.script.whileInFlight(0) { sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.script.count == 1 }
        await waitUntil(timeout: 0.3) { rig.sut.changesTabCount != nil }

        // then
        #expect(rig.sut.changesTabCount == nil)
        #expect(rig.sut.changesPresentation == .loading)
        #expect(!rig.script.calls[0].fence())
    }

    @Test func givenAnOpenPane_whenTheViewDisappearsAndReappears_thenTheFirstPaneReportReadsAgain() async throws {
        // given
        let rig = try await openChangesRig(reply: .snapshot(try ChangesJSON.availableListing()))
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 6 }

        // when
        rig.sut.didDisappear()
        #expect(rig.sut.changesPresentation == .loading)
        #expect(rig.sut.changesTabCount == nil)
        rig.sut.didAppear()
        rig.harness.tasksSubject.send([rig.scenario.task])
        await waitUntil { rig.sut.task != nil }
        #expect(await quietCallCount(rig) == 1, "an unreported pane is not demand")
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 6 }
        defer { rig.sut.didDisappear() }

        // then
        #expect(rig.script.count == 2)
    }

    @Test func givenASettlingLog_whenTheViewReappears_thenItReadsWithoutAPaneReport() async throws {
        // given
        let rig = try await openChangesRig(logState: .settling)
        await waitUntil { rig.script.count == 1 }
        rig.sut.didDisappear()

        // when
        rig.sut.didAppear()
        rig.harness.tasksSubject.send([rig.scenario.task])
        await waitUntil { rig.script.count == 2 }
        defer { rig.sut.didDisappear() }

        // then
        #expect(rig.script.calls[1].key.taskID == "t1")
    }

    @Test(arguments: [
        TaskChangesReadFailure.Outcome.failed(.timedOut(tool: "harflow-ctl", seconds: 30)),
        .clientBound(.deadline),
        .clientBound(.requestBudget),
        .failed(ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: ""))
    ])
    func givenAFailedRead_whenRetryIsTapped_thenANewGenerationReadsAndTheNextAnswerApplies(outcome: TaskChangesReadFailure.Outcome) async throws {
        // given
        let rig = try await openChangesRig(reply: .failure(outcome))
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { if case .note = rig.sut.changesPresentation { true } else { false } }
        rig.script.answerFromNowOn(.snapshot(try ChangesJSON.availableListing()))

        // when
        rig.sut.didTapRetryChanges()
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(rig.script.count == 2)
        #expect(rig.script.calls[1].key.generation > rig.script.calls[0].key.generation)
    }

    @Test func givenAnUnsupportedEngine_whenRead_thenTheNoteOffersRetryAndStaysUntilTapped() async throws {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: "")
        let rig = try await openChangesRig(reply: .failure(.failed(error)))
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesPresentation == .note(TaskChangesFailure.unsupported.note) }

        // then
        #expect(await quietCallCount(rig) == 1)
        #expect(TaskChangesFailure.unsupported.note.action == .retryRead)
    }

    @Test func givenAPendingLaunchRefusal_whenRead_thenTheNotStartedNoteShowsWithoutACount() async throws {
        // given
        let rig = try await openChangesRig(reply: .failure(.failed(ChangesJSON.pendingLaunch)))
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesPresentation == .note(TaskChangesFailure.notStarted.note) }

        // then
        #expect(rig.sut.changesTabCount == nil)
    }

    @Test func givenASupersededRead_whenItAnswers_thenItIsReadOnceMoreAndAnAnswerApplies() async throws {
        // given
        let rig = try await openChangesRig(reply: .snapshot(try ChangesJSON.availableListing()))
        defer { rig.sut.didDisappear() }
        rig.script.answer(0, .failure(.superseded))

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(rig.script.count == 2)
    }

    @Test func givenTwoSupersessionsInARow_whenTheSecondAnswers_thenTheTransportUnavailableNoteShows() async throws {
        // given
        let rig = try await openChangesRig(reply: .failure(.superseded))
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesPresentation == .note(TaskChangesFailure.unavailable.note) }

        // then
        #expect(rig.script.count == 2)
        #expect(await quietCallCount(rig) == 2)
        #expect(rig.sut.changesTabCount == nil)
        #expect(!rig.sut.changesCaptureSettling)
    }

    @Test func givenARereadInFlight_whenItStarts_thenTheTabCountIsClearedUntilTheResultApplies() async throws {
        // given
        let rig = try await openChangesRig(reply: .snapshot(try ChangesJSON.availableListing()))
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 6 }
        let sut = rig.sut
        let seen = PollCounter()
        rig.script.whileInFlight(1) { if sut.changesTabCount == nil { seen.increment() } }

        // when
        rig.sut.didTapRetryChanges()
        await waitUntil { rig.sut.changesTabCount == 6 && rig.script.count == 2 }

        // then
        #expect(seen.value == 1, "no count was drawn while the re-read was in flight")
    }

    @Test func givenAnAppliedListing_whenTheTaskDisappearsFromTheListing_thenEveryPieceOfChangesStateClears() async throws {
        // given
        let rig = try await openChangesRig(reply: .snapshot(try ChangesJSON.availableListing()))
        defer { rig.sut.didDisappear() }
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 6 }
        let scope = TaskChangesScopeID(taskID: "t1", repository: 0, scope: "committed_range")
        rig.sut.didTapLoadMoreChangeRows(scope: scope)

        // when
        rig.harness.detailBox.value = nil
        rig.harness.hasListedSubject.send(true)
        rig.harness.tasksSubject.send([])
        await waitUntil { rig.sut.task == nil }

        // then
        #expect(rig.sut.changesPresentation == .loading)
        #expect(rig.sut.changesTabCount == nil)
        #expect(!rig.sut.changesCaptureSettling)
        #expect(rig.sut.changesRevealLimits.isEmpty)

        // when: the task returns while the view still reports its pane open
        rig.harness.detailBox.value = rig.scenario.task
        rig.harness.tasksSubject.send([rig.scenario.task])
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(rig.script.count == 2)
    }

    @Test func givenTheLoadMoreAction_whenTapped_thenTheScopeRevealsTwoHundredMoreRowsPerStepAndLeavingClearsIt() async throws {
        // given
        let rig = try await openChangesRig()
        let scope = TaskChangesScopeID(taskID: "t1", repository: 0, scope: "committed_range")
        let other = TaskChangesScopeID(taskID: "t1", repository: 0, scope: "working_tree")

        // when
        rig.sut.didTapLoadMoreChangeRows(scope: scope)
        rig.sut.didTapLoadMoreChangeRows(scope: scope)

        // then
        #expect(rig.sut.changesRevealLimits[scope] == 600)
        #expect(rig.sut.changesRevealLimits[other] == nil)

        // when
        rig.sut.didDisappear()

        // then
        #expect(rig.sut.changesRevealLimits.isEmpty)
    }

    @Test func givenAConversationOpenedOnAnEarlierTurn_whenAFollowUpAppears_thenTheNewMemberIsReadAndLoadingShowsFirst() async throws {
        // given
        let scheduler = CapturingScheduler()
        let first = conversationTask("a", status: "completed", minute: 0)
        let second = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [first], stubbedMembers: [first, second], chrome: .standalone,
                                          scheduler: scheduler)
        let script = ChangesReadScript(.snapshot(try ChangesJSON.availableListing()))
        given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in script.serve(key, fence) }
        harness.sut.didAppear()
        harness.tasksSubject.send([first])
        await waitUntil { harness.sut.task != nil }
        harness.sut.setChangesPaneOpen(true)
        await waitUntil { harness.sut.changesTabCount == 6 }
        defer { harness.sut.didDisappear() }

        // when
        harness.membersBox.value = [first, second]
        harness.tasksSubject.send([first, second])
        await waitUntil { script.count == 2 }

        // then
        #expect(script.calls.map(\.key.taskID) == ["a", "b"])
        #expect(harness.sut.changesLifecycle.memberIDs == ["a", "b"])
        await waitUntil { harness.sut.changesTabCount == 6 }
    }
}
