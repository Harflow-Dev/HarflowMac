import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - Presentation settling

extension SidebarVM {
    func waitForPresentation() async {
        await waitUntil { self.presentationWorker == nil && self.pendingPresentationInput == nil }
    }
}

@MainActor
extension SidebarVM {
    func preparedBuilder() -> SidebarPresentationBuilder {
        var builder = SidebarPresentationBuilder(input: presentationInput())
        _ = try? builder.build()
        return builder
    }

    func filteredWorkflowRuns() -> [SidebarWorkflowRun] { preparedBuilder().visibleRuns }
    func workflowTreeItems(_ run: SidebarWorkflowRun) -> [SidebarItem] { preparedBuilder().workflowTreeItems(run) }
    func bucketedSections(trees: [ConversationNode], groups: [ParallelGroup], forcedExpandedIDs: Set<String>) -> [SidebarSection] {
        preparedBuilder().bucketedSections(trees: trees, groups: groups, forcedExpandedIDs: forcedExpandedIDs)
    }
}

// MARK: - Background scheduling regression tests

@MainActor
private final class SidebarBuildGate {
    var continuation: CheckedContinuation<Void, Never>?
    var requests = 0

    func pauseFirst() async {
        requests += 1
        guard requests == 1 else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

extension SidebarVMTests {
    @Test func givenDuplicateSnapshots_whenRebuilt_thenRenderingSettersStayQuiet() async {
        // given
        let harness = makeSUT()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        harness.sut.currentDate = { now }
        harness.sut.latestTasks = [task(id: "same", status: "completed", startedAt: now)]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        let writes = harness.sut.presentationWrites
        // when
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        harness.sut.taskHistoryState = harness.sut.taskHistoryState
        harness.sut.workflowErrorMessage = harness.sut.workflowErrorMessage
        // then
        #expect(harness.sut.presentationWrites == writes)
    }

    @Test func givenVisibleChanges_whenRebuilt_thenCompletePresentationRefreshes() async {
        // given
        let harness = makeSUT()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        harness.sut.currentDate = { now }
        harness.sut.latestTasks = [task(id: "same", status: "completed", startedAt: now)]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        let initial = harness.sut.sections
        // when
        harness.sut.latestTitles = ["same": "New title"]
        harness.sut.latestTasks = [task(id: "same", status: "running", startedAt: now)]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.sections != initial)
        #expect(harness.sut.runningRows.first?.title == "New title")
        #expect(harness.sut.runningRows.first?.status.isRunning == true)
        let writes = harness.sut.presentationWrites
        harness.sut.taskHistoryState.hasMore = true
        harness.sut.workflowHistoryState.isLoading = true
        harness.sut.workflowErrorMessage = "Failed"
        #expect(harness.sut.presentationWrites == writes + 3)
    }

    @Test func givenAnOlderBuild_whenSearchChangesRapidly_thenOnlyLatestPendingBuildApplies() async {
        // given
        let harness = makeSUT()
        let gate = SidebarBuildGate()
        harness.sut.latestTasks = [task(id: "first"), task(id: "last")]
        harness.sut.presentationBuild = { input in
            let result = SidebarPresentationBuilder.compute(input)
            await gate.pauseFirst()
            return result
        }
        harness.sut.recompute()
        await waitUntil { gate.continuation != nil }
        // when
        harness.sut.didChangeSearchQuery("first")
        harness.sut.didChangeSearchQuery("absent")
        harness.sut.didChangeSearchQuery("last")
        #expect(gate.requests == 1)
        #expect(harness.sut.sections.isEmpty)
        gate.release()
        await harness.sut.waitForPresentation()
        // then
        #expect(gate.requests == 2)
        #expect(harness.sut.runningRows.map(\.id) == ["last"])
    }

    @Test func givenAnActiveClockBuild_whenEquivalentPollsArrive_thenValidBuildIsNotCancelled() async {
        // given
        let harness = makeSUT()
        let gate = SidebarBuildGate()
        harness.sut.latestTasks = [task(id: "same")]
        harness.sut.presentationBuild = { input in
            let result = SidebarPresentationBuilder.compute(input)
            await gate.pauseFirst()
            return Task.isCancelled ? nil : result
        }
        harness.sut.recompute()
        await waitUntil { gate.continuation != nil }
        let revision = harness.sut.presentationRevision
        // when
        for _ in 0 ..< 10 { harness.sut.recompute() }
        #expect(harness.sut.presentationRevision == revision)
        #expect(gate.requests == 1)
        gate.release()
        await harness.sut.waitForPresentation()
        // then
        #expect(gate.requests == 2)
        #expect(harness.sut.runningRows.map(\.id) == ["same"])
    }

    @Test func givenAnActiveBuild_whenTeardownAndReopenOccur_thenPreviousLifecycleCannotPublish() async {
        // given
        let harness = makeSUT()
        let gate = SidebarBuildGate()
        harness.sut.latestTasks = [task(id: "old")]
        harness.sut.presentationBuild = { input in
            let result = SidebarPresentationBuilder.compute(input)
            await gate.pauseFirst()
            return result
        }
        harness.sut.recompute()
        await waitUntil { gate.continuation != nil }
        // when
        harness.sut.didDisappear()
        harness.sut.latestTasks = [task(id: "new")]
        harness.sut.didAppear()
        harness.sut.recompute()
        #expect(gate.requests == 1)
        gate.release()
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.runningRows.map(\.id) == ["new"])
        #expect(gate.requests == 2)
        harness.sut.didDisappear()
    }

    @Test func givenExplicitClockInput_whenAgeAndDayChange_thenPresentationChanges() async {
        // given
        let harness = makeSUT()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        harness.sut.currentDate = { now }
        harness.sut.latestTasks = [task(id: "dated", status: "completed", startedAt: now)]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        #expect(harness.sut.items(in: .today).count == 1)
        // when
        harness.sut.currentDate = { now.addingTimeInterval(172_800) }
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.items(in: .today).isEmpty)
        #expect(harness.sut.recentRows.first?.ageText == "2d")
        #expect(harness.sut.items(in: .earlier).count == 1)
    }
}

@MainActor
private final class SidebarThreadProbe {
    var value = false
}

extension SidebarVMTests {
    @Test func givenRawGroupContentChanges_whenPresentationRebuilds_thenVisibleSignatureStaysQuiet() async throws {
        // given
        let harness = makeSUT()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        harness.sut.currentDate = { now }
        let first = task(id: "a", status: "completed", startedAt: now, group: "Review")
        let second = task(id: "b", status: "completed", startedAt: now, group: "Review")
        harness.sut.latestTasks = [first, second]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        let writes = harness.sut.presentationWrites
        // when
        var raw = first.raw
        raw["prompt"] = .string("Different internal prompt")
        raw["summary"] = .string("Different internal answer")
        harness.sut.latestTasks = [try #require(TaskInfo(.object(raw))), second]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.presentationWrites == writes)
        raw["status"] = .string("running")
        raw["backend"] = .string("codex")
        harness.sut.latestTasks = [try #require(TaskInfo(.object(raw))), second]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        #expect(harness.sut.presentationWrites > writes)
        #expect(harness.sut.parallelGroups.first?.anyRunning == true)
    }

    @Test func givenSavedWorkflowMetadataChanges_whenNamesStayVisible_thenSavedRowsStayQuiet() async {
        // given
        let harness = makeSUT()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        harness.sut.currentDate = { now }
        harness.sut.workflowDefinitions = [WorkflowRecord(raw: ["name": .string("release"), "description": .string("Old")])]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        let writes = harness.sut.presentationWrites
        // when
        harness.sut.workflowDefinitions = [WorkflowRecord(raw: ["name": .string("release"), "description": .string("New")])]
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.savedWorkflows.map(\.id) == ["release"])
        #expect(harness.sut.presentationWrites == writes)
        harness.sut.didChangeSearchQuery("New")
        await harness.sut.waitForPresentation()
        #expect(harness.sut.savedWorkflows.map(\.id) == ["release"])
        harness.sut.didChangeSearchQuery("Old")
        await harness.sut.waitForPresentation()
        #expect(harness.sut.savedWorkflows.isEmpty)
    }

    @Test func givenPresentationWork_whenScheduled_thenBuilderExecutesOutsideTheMainThread() async {
        // given
        let harness = makeSUT()
        let observed = SidebarThreadProbe()
        harness.sut.latestTasks = [task(id: "background")]
        harness.sut.presentationBuild = { input in
            let background = Self.isBackgroundWorker()
            await MainActor.run { observed.value = background }
            return SidebarPresentationBuilder.compute(input)
        }
        // when
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        // then
        #expect(observed.value)
        #expect(harness.sut.runningRows.map(\.id) == ["background"])
    }

    @Test func givenASettledSelection_whenAnotherSidebarRowIsClicked_thenHighlightChangesBeforeWorkerSettles() async {
        let harness = makeSUT()
        harness.sut.latestTasks = [task(id: "previous"), task(id: "next")]
        harness.sut.didSelect(.task("previous"))
        await harness.sut.waitForPresentation()
        harness.sut.didSelect(.task("next"))
        #expect(harness.sut.selection == .task("next"))
        await harness.sut.waitForPresentation()
        #expect(harness.sut.selection == .task("next"))
    }

    private nonisolated static func isBackgroundWorker() -> Bool { !Thread.isMainThread }
    @Test func givenASelectedConversation_whenItsFollowupIsRequested_thenHighlightNeverPublishesRawMemberID() async {
        // given
        let harness = makeSUT()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        harness.sut.currentDate = { now }
        harness.sut.latestTasks = [task(id: "first", status: "completed", startedAt: now),
                                  task(id: "followup", status: "completed", startedAt: now.addingTimeInterval(1), parentTaskID: "first")]
        harness.sut.didSelect(.task("first"))
        await harness.sut.waitForPresentation()
        let writes = harness.sut.presentationWrites
        // when
        harness.sut.didSelect(.task("followup"))
        #expect(harness.sut.selection == .task("first"))
        await harness.sut.waitForPresentation()
        harness.sut.applyExternalSelection(.task("first"))
        #expect(harness.sut.selection == .task("first"))
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.selection == .task("first"))
        #expect(harness.sut.presentationWrites == writes)
    }

}
