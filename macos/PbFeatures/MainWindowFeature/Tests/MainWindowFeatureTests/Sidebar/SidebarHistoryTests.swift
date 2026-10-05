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
        vm.collapsedTaskIDs = ["collapsed"]
        // when
        vm.didTapLoadMoreWorkflows()
        await waitUntil { !vm.workflowHistoryState.isLoading }
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
