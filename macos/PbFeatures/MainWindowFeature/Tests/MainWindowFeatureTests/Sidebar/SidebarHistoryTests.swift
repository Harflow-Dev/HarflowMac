import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

@MainActor
struct SidebarHistoryTests {
    final class History: SidebarHistoryUseCase {
        let state = PassthroughSubject<HistoryLoadingState, Never>()
        var cursors: [String?] = []
        var batches: [[String]] = []
        var taskLoads = 0
        var page: HistoryPage!
        func taskHistoryStatePublisher() -> AnyPublisher<HistoryLoadingState, Never> { state.eraseToAnyPublisher() }
        func loadMoreTaskHistory() async { taskLoads += 1 }
        func resolveTask(_: String) async {}
        func workflowPage(cursor: String?, relatedRunID: String?) async throws -> HistoryPage {
            cursors.append(cursor)
            return page
        }

        func workflowBatch(runIDs: [String]) async throws -> HistoryPage {
            batches.append(runIDs)
            return page
        }
    }

    @Test(arguments: [false, true])
    func givenTaskCatalogBlock_whenPresentedAndRecovered_thenSidebarExposesRowsDiagnosticsAndReadRetry(initiallyLoaded: Bool) async {
        // given
        let harness = SidebarVMTests().makeSUT()
        let history = History()
        let vm = SidebarVM(useCase: harness.useCase, routing: harness.routing, historyUseCase: history)
        vm.didAppear()
        await vm.waitForPresentation()
        defer { vm.didDisappear() }
        if initiallyLoaded {
            harness.tasksSubject.send([SidebarVMTests().task(id: "loaded", status: "completed")])
            harness.hasListedSubject.send(true)
            await waitUntil { !vm.showsLoadingSkeleton }
            vm.didSelect(.task("loaded"))
        } else {
            harness.hasListedSubject.send(false)
            await waitUntil { vm.showsLoadingSkeleton }
        }
        var blocked = HistoryLoadingState()
        blocked.historyIncomplete = true
        blocked.catalogState = CatalogState(raw: ["catalog_state": .object([
            "status": .string("blocked"), "source": .string("task_catalog"), "reason": .string("Unsupported caller identity")
        ])])
        // when: a blocked response completes initial presentation without complete authority.
        history.state.send(blocked)
        harness.tasksSubject.send([SidebarVMTests().task(id: initiallyLoaded ? "loaded" : "placeholder", status: "completed")])
        harness.hasListedSubject.send(true)
        // then
        await waitUntil { !vm.showsLoadingSkeleton && vm.taskHistoryState.catalogState.status == .blocked }
        #expect(!vm.sections.isEmpty)
        #expect(vm.taskHistoryState.catalogState.reason == "Unsupported caller identity")
        #expect(vm.taskHistoryState.historyIncomplete)
        #expect(!vm.taskHistoryState.countsComplete)
        if initiallyLoaded { #expect(vm.selection == .task("loaded")) }
        // when: the visible retry is a read operation through the existing history seam.
        vm.didTapLoadMoreTasks()
        await waitUntil { history.taskLoads == 1 }
        var ready = HistoryLoadingState()
        ready.countsComplete = true
        history.state.send(ready)
        // then
        await waitUntil { vm.taskHistoryState.catalogState.isReady }
        #expect(!vm.showsLoadingSkeleton)
        #expect(!vm.sections.isEmpty)
        #expect(!vm.taskHistoryState.historyIncomplete)
        if initiallyLoaded { #expect(vm.selection == .task("loaded")) }
    }

    private func page(_ ids: [String], next: String? = nil, status: String = "completed") throws -> HistoryPage {
        try #require(HistoryPage(raw: ["items": .array(ids.map {
            .object(["workflow_run_id": .string($0), "status": .string(status)])
        }), "next_cursor": next.map(JSONValue.string) ?? .null, "has_more": .bool(next != nil), "bootstrap_pending": .bool(false)]))
    }

    @Test func givenLoadedPagesWithSelectionAndCollapse_whenLoadingOneMore_thenCursorSelectionAndCollapseRemain() async throws {
        // given
        let harness = SidebarVMTests().makeSUT()
        let history = History()
        history.page = try page(["older"], next: "page3")
        let vm = SidebarVM(useCase: harness.useCase, routing: harness.routing, historyUseCase: history)
        vm.mergeWorkflowHeaders(try page(["current"], next: "page2").items)
        vm.updateWorkflowHistory(try page(["current"], next: "page2"), advancing: false)
        vm.didSelect(.workflowRun("current"))
        await vm.waitForPresentation()
        vm.collapsedTaskIDs = ["collapsed"]
        // when
        vm.didTapLoadMoreWorkflows()
        await waitUntil { !vm.workflowHistoryState.isLoading }
        await vm.waitForPresentation()
        vm.updateWorkflowHistory(try page(["newest"], next: "page2"), advancing: false)
        // then
        #expect(history.cursors.count == 1)
        #expect(history.cursors.first! == "page2")
        #expect(vm.workflowHistoryState.nextCursor == "page3")
        #expect(Set(vm.workflowRuns.map(\.id)) == ["current", "older"])
        #expect(vm.selection == .workflowRun("current"))
        #expect(vm.collapsedTaskIDs == ["collapsed"])
    }

    @Test func given150LoadedActiveRuns_whenPolling_thenOnlyBoundedOlderBatchUpdatesWithoutResettingHistory() async throws {
        // given
        let harness = SidebarVMTests().makeSUT()
        let history = History()
        history.page = try page((100 ..< 150).map { "run-\($0)" })
        let vm = SidebarVM(useCase: harness.useCase, routing: harness.routing, historyUseCase: history)
        vm.mergeWorkflowHeaders(try page((0 ..< 100).map { "run-\($0)" }, status: "running").items)
        vm.mergeWorkflowHeaders(try page((100 ..< 150).map { "run-\($0)" }, status: "running").items)
        // when
        await vm.refreshLoadedWorkflowStatus(excluding: Set((0 ..< 100).map { "run-\($0)" }))
        // then
        #expect(history.batches.count == 1)
        #expect(history.batches.first?.count == 50)
        #expect(vm.workflowRuns.first { $0.id == "run-120" }?.isActive == false)
        #expect(vm.workflowRuns.count == 150)
    }
}
