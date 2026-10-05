import Foundation
@testable import MenuBarFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

// MARK: - WorkflowMenuBarStatusVMTests

@MainActor
@Suite struct WorkflowMenuBarStatusVMTests {
    final class Pages: WorkflowMenuBarUseCase, WorkflowMenuBarPageUseCase {
        var page: HistoryPage
        init(page: HistoryPage) { self.page = page }
        func runs() async throws -> [[String: JSONValue]] { [] }
        func activePage() async throws -> HistoryPage { page }
    }

    @Test func givenMoreActiveRootsThanVisiblePage_whenRefreshed_thenBadgeUsesCatalogTotals() async throws {
        // given
        let page = try #require(HistoryPage(raw: ["items": .array([.object(run("visible", status: "running"))]),
            "next_cursor": .string("next"), "has_more": .bool(true), "bootstrap_pending": .bool(false),
            "total_active_count": .number(400), "total_active_root_count": .number(250), "total_attention_root_count": .number(12)]))
        let vm = WorkflowMenuBarStatusVM(useCase: Pages(page: page))
        // when
        await vm.refresh()
        // then
        #expect(vm.rows.count == 1)
        #expect(vm.activeCount == 250)
        #expect(vm.attentionCount == 12)
    }

    @Test func givenBootstrapCounts_whenRefreshing_thenColdCountsStayUnknownAndLastCompleteCountsSurvive() async throws {
        // given
        var raw: [String: JSONValue] = ["items": .array([.object(run("partial", status: "running"))]),
            "next_cursor": .null, "has_more": .bool(false), "bootstrap_pending": .bool(true),
            "total_active_count": .number(2), "total_active_root_count": .number(1), "total_attention_root_count": .number(0)]
        let pages = Pages(page: try #require(HistoryPage(raw: raw)))
        let vm = WorkflowMenuBarStatusVM(useCase: pages)
        // when / then: the first partial inventory is explicitly unknown.
        await vm.refresh()
        #expect(vm.countsLoading)
        #expect(vm.activeCount == 0)
        raw["bootstrap_pending"] = .bool(false)
        raw["total_active_root_count"] = .number(250)
        raw["total_attention_root_count"] = .number(12)
        pages.page = try #require(HistoryPage(raw: raw))
        await vm.refresh()
        #expect(!vm.countsLoading)
        #expect(vm.activeCount == 250)
        // when another indexing generation begins, previously verified counts remain visible.
        raw["bootstrap_pending"] = .bool(true)
        raw["total_active_root_count"] = .null
        raw["total_attention_root_count"] = .null
        pages.page = try #require(HistoryPage(raw: raw))
        await vm.refresh()
        // then
        #expect(vm.countsLoading)
        #expect(vm.activeCount == 250)
        #expect(vm.attentionCount == 12)
    }

    func run(_ id: String, status: String) -> [String: JSONValue] {
        ["workflow_run_id": .string(id), "name": .string(id), "status": .string(status)]
    }

    @Test func givenWorkflowsWithoutAgentTasks_whenRefreshed_thenBadgeIncludesRunningPausedAndAttention() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        given(useCase).runs().willReturn([
            run("running", status: "running"), run("paused", status: "paused"),
            run("attention", status: "needs_attention"), run("done", status: "completed")
        ])
        let sut = WorkflowMenuBarStatusVM(useCase: useCase)
        // when
        await sut.refresh()
        // then
        #expect(sut.activeCount == 3)
        #expect(sut.attentionCount == 1)
        #expect(sut.rows.count == 4)
        #expect(sut.rows.first { $0.id == "paused" }?.statusLabel == "Paused")
    }

    @Test func givenLabelAndPopoverAppearances_whenSubscribedRepeatedly_thenOnePollStartsAndReappearanceCanRestart() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        let calls = WorkflowPollCalls()
        let row = run("running", status: "running")
        given(useCase).runs().willProduce { calls.increment(); return [row] }
        let sut = WorkflowMenuBarStatusVM(useCase: useCase)
        // when
        sut.didAppear()
        sut.didAppear()
        await waitUntil { sut.activeCount == 1 }
        // then
        verify(useCase).runs().called(1)
        sut.didDisappear()
        sut.didDisappear()
        sut.didAppear()
        await waitUntil { calls.value == 2 }
        verify(useCase).runs().called(2)
        sut.didDisappear()
    }

    @Test func givenOlderCLI_whenWorkflowListingFails_thenAgentMonitoringIsNotReplacedByAnInstallError() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        given(useCase).runs().willThrow(ToolError.unsupportedCommand(tool: "polybridge-ctl", command: "workflow-list-runs", detail: "older CLI"))
        let sut = WorkflowMenuBarStatusVM(useCase: useCase)
        // when
        await sut.refresh()
        // then
        #expect(sut.rows.isEmpty)
        #expect(sut.activeCount == 0)
        #expect(sut.errorText == "Workflow status unavailable")
    }
}

// MARK: - WorkflowPollCalls

private final class WorkflowPollCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

extension MenuBarVMTests {
    @Test func givenWorkflowStatusRow_whenSelected_thenItsPersistedRunOpensInTheMonitor() {
        // given
        let harness = makeSUT()
        // when
        harness.sut.didSelectWorkflow("workflow-run")
        // then
        verify(harness.routing).select(.value(.workflowRun("workflow-run"))).called(1)
        verify(harness.routing).openWindow().called(1)
        #expect(harness.sut.runningCount == 0)
    }
}

extension WorkflowMenuBarStatusVMTests {
    @Test func givenInputRequestAndTerminalSettling_whenMapped_thenBothRemainActiveWithCorrectIndicators() throws {
        // given / when
        let input = try #require(WorkflowMenuBarRow(["workflow_run_id": .string("input"), "status": .string("needs_input")]))
        let settling = try #require(WorkflowMenuBarRow(["workflow_run_id": .string("settling"), "status": .string("failed"), "settling": .bool(true)]))
        // then
        #expect(input.isActive && input.needsAttention && !input.isWorking)
        #expect(settling.isActive && settling.isWorking)
        #expect(settling.statusLabel == "Settling")
    }
}

extension WorkflowMenuBarStatusVMTests {
    @Test func givenChildQuestion_whenRefreshed_thenOneRootBadgeShowsChildAttention() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        var child = run("child", status: "needs_input")
        child["root_workflow_run_id"] = .string("root")
        child["attention_reason"] = .string("Choose an option")
        given(useCase).runs().willReturn([run("root", status: "paused"), child])
        let sut = WorkflowMenuBarStatusVM(useCase: useCase)
        // when
        await sut.refresh()
        // then
        #expect(sut.rows.map(\.id) == ["root"])
        #expect(sut.activeCount == 1)
        #expect(sut.attentionCount == 1)
        #expect(sut.rows.first?.detail == "child: Choose an option")
    }

    @Test func givenCompletedRootWithSettlingChild_whenRefreshed_thenTreeRemainsActive() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        var child = run("child", status: "running")
        child["root_workflow_run_id"] = .string("root")
        given(useCase).runs().willReturn([run("root", status: "completed"), child])
        let sut = WorkflowMenuBarStatusVM(useCase: useCase)
        // when
        await sut.refresh()
        // then
        #expect(sut.activeCount == 1)
        #expect(sut.rows.count == 1)
    }
}
