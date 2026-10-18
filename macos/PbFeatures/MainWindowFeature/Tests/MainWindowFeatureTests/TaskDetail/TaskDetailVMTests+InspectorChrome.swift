import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// Redesign phase 5, settled plan D14/D17: the inspector's Details, "Started by" and copy buttons.
extension TaskDetailVMTests {

    @Test func givenATopLevelTask_whenBuildingTheInspector_thenStartedByIsTopLevelTask() async {
        // given
        let harness = makeSUT()
        let top = task(status: "running")
        harness.detailBox.value = top
        harness.sut.didAppear()

        // when
        harness.tasksSubject.send([top])
        await waitUntil { harness.sut.inspectorModel != nil }

        // then
        #expect(harness.sut.inspectorModel?.startedBy == "Top-level task")
    }

    @Test func givenASubTask_whenBuildingTheInspector_thenStartedByIsTheParentsTitle() async {
        // given
        let harness = makeSUT()
        let child = task(status: "running", spawnedBy: "parent01")
        harness.detailBox.value = child
        harness.sut.didAppear()

        // when
        harness.tasksSubject.send([child])
        await waitUntil { harness.sut.inspectorModel != nil }

        // then
        #expect(harness.sut.inspectorModel?.startedBy == "Task parent01")
    }

    @Test func givenNoParent_whenFormattingStartedBy_thenItIsTopLevelTask() {
        // given / when / then
        #expect(InspectorModel.startedByText(parentTitle: nil) == "Top-level task")
        #expect(InspectorModel.startedByText(parentTitle: "Fix the build") == "Fix the build")
    }

    @Test func givenASnapshotWithAResumeCommand_whenBuildingTheInspector_thenTheCopyButtonIsAvailable() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.snapshotBox.value = task(status: "running", resumeCommand: "cd /repo && claude --resume s")
        harness.sut.didAppear()

        // when
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.inspectorModel?.resumeCommand != nil }

        // then
        #expect(harness.sut.inspectorModel?.resumeCommand == "cd /repo && claude --resume s")
    }

    @Test func givenTheInspectorsCopyTaskID_whenInvoked_thenTheCurrentRunsIDIsCopiedAndTheOutcomeRecorded() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        given(harness.routing).copyToPasteboard(.value("abc12345")).willReturn(true)
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.inspectorModel != nil }

        // when
        harness.sut.inspectorModel?.onCopyTaskID()

        // then
        await verify(harness.routing).copyToPasteboard(.value("abc12345")).calledEventually(1, before: .seconds(5))
        await verify(harness.useCase).setOutcome(.value("abc12345"), .value("Copied task ID.")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenAFailedPasteboardWrite_whenCopyingTheTaskID_thenTheOutcomeSaysSo() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        given(harness.routing).copyToPasteboard(.value("abc12345")).willReturn(false)
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }

        // when
        harness.sut.didTapCopyTaskID()

        // then
        await verify(harness.useCase).setOutcome(.value("abc12345"), .value("Couldn't copy to the clipboard.")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenATask_whenCopyingTheRepoPath_thenThePathIsCopiedAndTheOutcomeSaysSo() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/Users/example/Code/polybridge")
        harness.detailBox.value = running
        given(harness.routing).copyToPasteboard(.value("/Users/example/Code/polybridge")).willReturn(true)
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }

        // when
        harness.sut.didTapCopyRepoPath()

        // then
        await verify(harness.useCase).setOutcome(.value("abc12345"), .value("Copied path.")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenAFailedPasteboardWrite_whenCopyingTheRepoPath_thenTheOutcomeSaysSo() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        given(harness.routing).copyToPasteboard(.value("/repo")).willReturn(false)
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }

        // when
        harness.sut.didTapCopyRepoPath()

        // then
        await verify(harness.useCase).setOutcome(.value("abc12345"), .value("Couldn't copy to the clipboard.")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenATaskTheListingKnows_whenReadingTheLoadingHeader_thenItCarriesItsTitleAndRepoName() {
        // given — no didAppear: the skeleton shows before the view subscribes.
        let harness = makeSUT()
        harness.detailBox.value = task(status: "running", repoPath: "/Users/example/Code/Carousell-iOS")

        // when
        let header = harness.sut.loadingHeader

        // then
        #expect(header == TaskLoadingHeader(title: "Task abc12345", repoName: "Carousell-iOS"))
    }

    @Test func givenATaskTheListingDoesNotKnowYet_whenReadingTheLoadingHeader_thenThereIsNone() {
        // given
        let harness = makeSUT()
        harness.detailBox.value = nil

        // when / then
        #expect(harness.sut.loadingHeader == nil)
    }

    @Test func givenTheTabs_whenListingThem_thenTheirLabelsAreActivitySummaryPrompt() {
        // given / when / then
        #expect(TaskTab.allCases.map(\.rawValue) == ["Activity", "Summary", "Prompt"])
    }
}
