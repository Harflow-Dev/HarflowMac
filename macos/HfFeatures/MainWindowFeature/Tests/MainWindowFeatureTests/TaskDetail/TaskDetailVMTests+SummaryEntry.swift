import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

/// The Summary entry as the VM wires it: the explicit `chrome` mount, the evidence the builder reads from the
/// observation frame and snapshot, the published `summaryEntryShown` flag and its reset.
@MainActor
extension TaskDetailVMTests {

    private var entryTaskID: String { SummaryEntryScenario.taskID }

    /// Wires one finished conversation with the scenario's evidence and opens the screen.
    private func openedHarness(_ scenario: SummaryEntryScenario, chrome: TaskDetailChrome) async -> SUT {
        let harness = makeSUT(taskID: entryTaskID, chrome: chrome)
        harness.detailBox.value = scenario.task
        harness.snapshotBox.value = scenario.snapshot
        harness.observationBox.value = scenario.frame
        // A settling log with the standalone mount reads stored changes; these tests do not examine that read.
        given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "unavailable"))))
        }
        harness.sut.didAppear()
        harness.tasksSubject.send([scenario.task])
        await waitUntil { harness.sut.task != nil && harness.sut.timelineWorker == nil && !harness.sut.timelineModel.activityRows.isEmpty }
        return harness
    }

    private func publish(_ scenario: SummaryEntryScenario, to harness: SUT) {
        harness.detailBox.value = scenario.task
        harness.snapshotBox.value = scenario.snapshot
        harness.observationBox.value = scenario.frame
        harness.observationSubject.send(scenario.frame)
        harness.snapshotsSubject.send([entryTaskID: scenario.snapshot ?? scenario.task])
        harness.tasksSubject.send([scenario.task])
    }

    private func lastEntry(_ harness: SUT) -> SummaryEntry? {
        if case .summary(let entry) = harness.sut.timelineModel.activityRows.last { return entry }
        return nil
    }

    // MARK: Mount

    @Test(arguments: [(TaskDetailChrome.standalone, true), (.group, false), (.embedded, false)])
    func givenAChrome_whenTheVMIsBuilt_thenOnlyTheStandaloneMountShowsTheEntry(chrome: TaskDetailChrome, shows: Bool) {
        // given / when
        let harness = makeSUT(taskID: entryTaskID, chrome: chrome)
        // then
        #expect(harness.sut.chrome == chrome)
        #expect(harness.sut.showsSummaryEntry == shows)
    }

    @Test func givenAWorkflowBuilderVM_whenBuiltByTheFactories_thenItUsesTheEmbeddedMount() {
        // given / when
        let single = makeSUT(taskID: entryTaskID, isWorkflowBuilder: true, chrome: .standalone)
        let conversation = makeConversationSUT(openedAs: "a", initialMembers: [conversationTask("a")], isWorkflowBuilder: true, chrome: .standalone)
        // then
        #expect(single.sut.chrome == .embedded)
        #expect(conversation.sut.chrome == .embedded)
    }

    @Test func givenTheCoordinatorBuiltTaskDetail_whenInspected_thenItsVMServesTheStandaloneMount() throws {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        // when
        let view = sut.buildTaskDetailView(id: "abc123")
        // then
        let model = try #require(Self.findTaskDetailVM(in: view))
        #expect(model.chrome == .standalone)
        #expect(model.showsSummaryEntry)
    }

    private static func findTaskDetailVM(in value: Any, depth: Int = 0) -> TaskDetailVM? {
        guard depth < 16 else { return nil }
        if let model = value as? TaskDetailVM { return model }
        for child in Mirror(reflecting: value).children {
            if let found = findTaskDetailVM(in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: Evidence

    @Test func givenStandaloneAndCompleteEvidence_whenOpened_thenTheEntryIsTheLastRowAndTheFlagIsSet() async {
        // given / when
        let harness = await openedHarness(SummaryEntryScenario(), chrome: .standalone)
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.summaryEntryShown }
        // then
        #expect(harness.sut.summaryEntryShown)
        #expect(lastEntry(harness)?.text == SummaryEntryScenario.summary)
        #expect(lastEntry(harness)?.id == "t1#summary")
        #expect(harness.sut.appliedTimelinePresentation?.summaryEntryShown == true)
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenTheSameEvidence_whenTheMountIsNotStandalone_thenThereIsNoEntry(chrome: TaskDetailChrome) async {
        // given / when
        let harness = await openedHarness(SummaryEntryScenario(), chrome: chrome)
        defer { harness.sut.didDisappear() }
        // then
        #expect(!harness.sut.summaryEntryShown)
        #expect(lastEntry(harness) == nil)
        #expect(harness.sut.appliedTimelinePresentation?.summaryDecision == nil)
    }

    @Test func givenTheEntryIsShown_whenTheResultIsRead_thenTheEntryAndTheResultSectionCarryTheSameText() async {
        // given / when
        let harness = await openedHarness(SummaryEntryScenario(), chrome: .standalone)
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.summaryEntryShown && harness.sut.summaryModel.finalAnswer != nil }
        // then
        #expect(harness.sut.summaryModel.finalAnswer == lastEntry(harness)?.text)
    }

    @Test func givenAManagedEnvelope_whenShown_thenTheEntryAndTheResultSectionAgreeOnTheProjectedText() async {
        // given
        var scenario = SummaryEntryScenario()
        scenario.taskFields = ["workflow_role": .string("node"), "execution_contract": .string("delegation")]
        scenario.snapshotSummary = #"{"status":"succeeded","result":{"answer":"Done"},"evidence":["checked"]}"#
        // when
        let harness = await openedHarness(scenario, chrome: .standalone)
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.summaryEntryShown && harness.sut.summaryModel.finalAnswer != nil }
        // then
        let entry = lastEntry(harness)
        #expect(entry?.text.hasPrefix("Succeeded") == true)
        #expect(harness.sut.summaryModel.finalAnswer == entry?.text)
    }

    // MARK: Live sequence

    @Test func givenARunningTask_whenItCompletesAndThenTheLogGoesFinal_thenTheEntryAppearsOnlyAtTheEnd() async {
        // given — running, log open.
        var scenario = SummaryEntryScenario()
        scenario.taskStatus = "running"
        scenario.snapshotStatus = "running"
        scenario.snapshotSummary = nil
        scenario.logState = .open
        let harness = await openedHarness(scenario, chrome: .standalone)
        defer { harness.sut.didDisappear() }
        #expect(!harness.sut.summaryEntryShown)

        // when — the task completes with a summary while the log is still settling.
        scenario.taskStatus = "completed"
        scenario.snapshotStatus = "completed"
        scenario.snapshotSummary = SummaryEntryScenario.summary
        scenario.logState = .settling
        publish(scenario, to: harness)
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.task?.status == .completed }
        await waitUntil(timeout: 0.3) { harness.sut.summaryEntryShown }
        // then
        #expect(!harness.sut.summaryEntryShown)
        #expect(lastEntry(harness) == nil)

        // when — the log goes final.
        scenario.logState = .final
        publish(scenario, to: harness)
        await waitUntil { harness.sut.summaryEntryShown }
        // then
        #expect(harness.sut.summaryEntryShown)
        #expect(lastEntry(harness)?.text == SummaryEntryScenario.summary)
    }

    @Test func givenAnUndecidedEntry_whenPagingSuppliesTextEvidence_thenTheEntryAppears() async {
        // given — a tool-only final turn with older history unread.
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.tool(2, path: "/repo/a.swift")]
        scenario.hasOlder = true
        let harness = await openedHarness(scenario, chrome: .standalone)
        defer { harness.sut.didDisappear() }
        await waitUntil(timeout: 0.3) { harness.sut.summaryEntryShown }
        #expect(!harness.sut.summaryEntryShown)

        // when — an older page brings an assistant text.
        scenario.items = [SummaryEntryScenario.text(1, "Earlier message.")] + scenario.items
        publish(scenario, to: harness)
        await waitUntil { harness.sut.summaryEntryShown }
        // then
        #expect(harness.sut.summaryEntryShown)
        #expect(lastEntry(harness)?.text == SummaryEntryScenario.summary)
    }

    @Test func givenTheEntryIsShown_whenTheLogIsWithdrawn_thenTheEntryGoesAway() async throws {
        // given
        let scenario = SummaryEntryScenario()
        let harness = await openedHarness(scenario, chrome: .standalone)
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.summaryEntryShown }
        try #require(harness.sut.summaryEntryShown)
        // when — a capacity or nonprogress refusal withholds the log state.
        var withdrawn = scenario
        withdrawn.logState = nil
        publish(withdrawn, to: harness)
        await waitUntil { !harness.sut.summaryEntryShown }
        // then
        #expect(!harness.sut.summaryEntryShown)
        #expect(lastEntry(harness) == nil)
    }

    @Test func givenTheTaskDisappears_whenTheEntryWasShown_thenTheFlagIsCleared() async throws {
        // given
        let harness = await openedHarness(SummaryEntryScenario(), chrome: .standalone)
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.summaryEntryShown }
        try #require(harness.sut.summaryEntryShown)
        // when
        harness.detailBox.value = nil
        harness.snapshotBox.value = nil
        harness.hasListedSubject.send(true)
        harness.tasksSubject.send([])
        await waitUntil { !harness.sut.summaryEntryShown }
        // then
        #expect(!harness.sut.summaryEntryShown)
    }

    // MARK: Publication

    @Test func givenTheSameEntryState_whenPresentationsAreAppliedAgain_thenNothingIsWrittenAndAChangeIsWrittenOnce() throws {
        // given
        let harness = makeSUT(taskID: entryTaskID, chrome: .standalone)
        let shown = try SummaryEntryScenario().build()
        var hiddenScenario = SummaryEntryScenario()
        hiddenScenario.shows = false
        let hidden = try hiddenScenario.build()
        let counter = EntryWriteCounter()
        func track() {
            withObservationTracking { _ = harness.sut.summaryEntryShown } onChange: {
                MainActor.assumeIsolated { counter.writes += 1 }
            }
        }
        track()

        // when
        harness.sut.applyTimeline(shown)
        let afterFirst = counter.writes
        track()
        harness.sut.applyTimeline(shown)
        let afterDuplicate = counter.writes
        harness.sut.applyTimeline(hidden)

        // then
        #expect(afterFirst == 1)
        #expect(afterDuplicate == 1)
        #expect(counter.writes == 2)
        #expect(!harness.sut.summaryEntryShown)
    }
}

@MainActor private final class EntryWriteCounter { var writes = 0 }
