import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

@MainActor
struct SidebarInfiniteHistoryTests {
    final class History: SidebarHistoryUseCase {
        let state = PassthroughSubject<HistoryLoadingState, Never>()
        var taskLoads = 0
        var cursors: [String?] = []
        var pages: [HistoryPage] = []
        var failure: ToolError?
        var held: CheckedContinuation<HistoryPage, Error>?
        var hold = false
        var holdTasks = false
        var heldTask: CheckedContinuation<Void, Never>?
        func taskHistoryStatePublisher() -> AnyPublisher<HistoryLoadingState, Never> { state.eraseToAnyPublisher() }
        func loadMoreTaskHistory() async {
            taskLoads += 1
            if holdTasks { await withCheckedContinuation { heldTask = $0 } }
        }

        func resolveTask(_: String) async {}
        func workflowBatch(runIDs _: [String]) async throws -> HistoryPage { pages[0] }
        func workflowPage(cursor: String?, relatedRunID _: String?) async throws -> HistoryPage {
            cursors.append(cursor)
            if hold { return try await withCheckedThrowingContinuation { held = $0 } }
            if let failure { throw failure }
            return pages.removeFirst()
        }
    }

    private func page(next: String?, id: String = "older", catalog: String = "ready") throws -> HistoryPage {
        try #require(HistoryPage(raw: [
            "items": .array([.object(["workflow_run_id": .string(id), "status": .string("completed")])]),
            "next_cursor": next.map(JSONValue.string) ?? .null, "has_more": .bool(next != nil),
            "bootstrap_pending": .bool(false), "catalog_state": .object(["status": .string(catalog)])
        ]))
    }

    private func vm(_ history: History) -> SidebarVM {
        let harness = SidebarVMTests().makeSUT()
        return SidebarVM(useCase: harness.useCase, routing: harness.routing, historyUseCase: history)
    }

    @Test func givenRepeatedBottomEvents_whenPageIsInFlight_thenOnlyOneRequestStarts() async throws {
        let history = History()
        history.hold = true
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { history.held != nil }
        #expect(history.cursors == ["page2"])
        history.held?.resume(returning: try page(next: nil))
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        await sut.waitForPresentation()
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        #expect(history.cursors.count == 1)
        sut.didDisappear()
    }

    @Test func givenShortPage_whenFreshLayoutStillShowsBottom_thenNextPageLoadsSequentially() async throws {
        let history = History()
        history.pages = [try page(next: "page3"), try page(next: nil, id: "oldest")]
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        await sut.waitForPresentation()
        #expect(history.cursors == ["page2"])
        // A fresh post-presentation viewport measurement grants the next page.
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        await sut.waitForPresentation()
        #expect(history.cursors == ["page2", "page3"])
        #expect(!sut.workflowHistoryState.hasMore)
        sut.didDisappear()
    }

    @Test func givenOldViewportMeasurement_whenAppendedPresentationSettles_thenFreshLayoutRequired() async throws {
        let history = History()
        history.pages = [try page(next: "page3"), try page(next: nil, id: "oldest")]
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        let oldRevision = sut.historyPresentationRevision
        sut.didChangeHistoryBottomVisibility(true, revision: oldRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        await sut.waitForPresentation()
        #expect(sut.historyPresentationRevision > oldRevision)
        sut.didChangeHistoryBottomVisibility(true, revision: oldRevision)
        #expect(history.cursors.count == 1)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        #expect(history.cursors.count == 2)
        sut.didDisappear()
    }

    @Test func givenCursorDoesNotAdvance_whenBottomRemainsVisible_thenAutomaticLoopStops() async throws {
        let history = History()
        history.pages = [try page(next: "page2")]
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        await sut.waitForPresentation()
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        #expect(history.cursors.count == 1)
        sut.didDisappear()
    }

    @Test(arguments: ["blocked", "preparing", "error", "authority", "exhausted", "cursor"])
    func givenUnavailableHistory_whenBottomIsVisible_thenDoesNotAutomaticallyLoad(reason: String) async throws {
        let history = History()
        let sut = vm(history)
        var state = HistoryLoadingState()
        state.hasMore = true
        state.nextCursor = "page2"
        switch reason {
        case "blocked": state.catalogState = CatalogState(raw: ["catalog_state": .object(["status": .string("blocked")])])
        case "preparing": state.bootstrapPending = true
        case "error": state.error = .unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "fixture failure")
        case "authority": state.authorityIncomplete = true
        case "exhausted": state.hasMore = false
        default: state.nextCursor = nil
        }
        sut.workflowHistoryState = state
        sut.taskHistoryState = state
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        #expect(sut.workflowHistoryLoadTask == nil)
        #expect(sut.taskHistoryLoadTask == nil)
        #expect(history.cursors.isEmpty)
        #expect(history.taskLoads == 0)
    }

    @Test func givenLoadFailure_whenBottomEventsRepeat_thenOnlyExplicitRetryRestarts() async throws {
        let history = History()
        history.failure = .unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "fixture failure")
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        await sut.waitForPresentation()
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        #expect(history.cursors.count == 1)
        history.failure = nil
        history.pages = [try page(next: nil)]
        sut.didTapLoadMoreWorkflows()
        await waitUntil { sut.workflowHistoryLoadTask == nil }
        #expect(history.cursors.count == 2)
        #expect(sut.workflowHistoryState.error == nil)
        sut.didDisappear()
    }

    @Test func givenPendingPage_whenSidebarDisappears_thenCompletionDoesNotMutateHistory() async throws {
        let history = History()
        history.hold = true
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { history.held != nil }
        sut.didDisappear()
        history.held?.resume(returning: try page(next: nil, id: "stale"))
        await Task.yield()
        #expect(sut.workflowRuns.isEmpty)
        #expect(sut.workflowHistoryState.nextCursor == "page2")
        #expect(!sut.historyBottomVisible)
    }

    @Test func givenDuplicateTaskViewportEvents_whenCursorIsUnchanged_thenSingleRead() async {
        let history = History()
        let sut = vm(history)
        sut.taskHistoryState.hasMore = true
        sut.taskHistoryState.nextCursor = "task2"
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { history.taskLoads == 1 && sut.taskHistoryLoadTask == nil }
        await sut.waitForPresentation()
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        #expect(history.taskLoads == 1)
        sut.didDisappear()
    }

    @Test func givenCancelledPages_whenSidebarReopens_thenSameCursorsCanLoadAgain() async throws {
        // given
        let history = History()
        history.hold = true
        history.holdTasks = true
        let sut = vm(history)
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.taskHistoryState.hasMore = true
        sut.taskHistoryState.nextCursor = "task2"
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { history.held != nil && history.heldTask != nil }
        let oldWorkflowLoad = sut.workflowHistoryLoadTask
        let oldTaskLoad = sut.taskHistoryLoadTask
        // when
        sut.didDisappear()
        history.held?.resume(returning: try page(next: nil, id: "stale"))
        history.heldTask?.resume()
        await oldWorkflowLoad?.value
        await oldTaskLoad?.value
        history.hold = false
        history.holdTasks = false
        history.pages = [try page(next: nil, id: "fresh")]
        sut.didAppear()
        await sut.waitForPresentation()
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { sut.workflowHistoryLoadTask == nil && sut.taskHistoryLoadTask == nil }
        await sut.waitForPresentation()
        // then
        #expect(history.cursors == ["page2", "page2"])
        #expect(history.taskLoads == 2)
        #expect(sut.workflowRuns.map(\.id) == ["fresh"])
        #expect(!sut.workflowHistoryState.hasMore)
        sut.didDisappear()
    }

    @Test(arguments: [false, true])
    func givenPendingWorkflowPage_whenPollingRestarts_thenSameCursorRetriesAndStaleCompletionCannotClearNewRequest(fails: Bool) async throws {
        // given — the reader deliberately ignores cancellation until its response arrives.
        let history = History()
        history.hold = true
        let sut = vm(history)
        defer { sut.didDisappear() }
        sut.updateWorkflowHistory(try page(next: "page2"), advancing: true)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { history.held != nil }
        let oldResponse = try #require(history.held)
        let oldLoad = try #require(sut.workflowHistoryLoadTask)
        history.held = nil
        // when — use the same stop/start sequence as the Refresh workflows recovery action.
        sut.stopWorkflowPolling()
        sut.startWorkflowPolling()
        #expect(oldLoad.isCancelled)
        #expect(sut.workflowHistoryLoadTask == nil)
        #expect(!sut.workflowHistoryState.isLoading)
        sut.didChangeHistoryBottomVisibility(true, revision: sut.historyPresentationRevision)
        await waitUntil { history.held != nil }
        let freshResponse = history.held
        let freshLoad = sut.workflowHistoryLoadTask
        if fails {
            oldResponse.resume(throwing: ToolError.unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "stale failure"))
        } else {
            oldResponse.resume(returning: try page(next: nil, id: "stale"))
        }
        await oldLoad.value
        // then — the new request owns loading and cursor state even after the old request finishes.
        #expect(history.cursors == ["page2", "page2"])
        #expect(sut.workflowHistoryLoadTask != nil)
        #expect(sut.workflowHistoryState.isLoading)
        #expect(sut.workflowHistoryState.nextCursor == "page2")
        #expect(sut.workflowHistoryState.error == nil)
        #expect(sut.workflowRuns.isEmpty)
        freshResponse?.resume(returning: try page(next: nil, id: "fresh"))
        await freshLoad?.value
        #expect(sut.workflowHistoryLoadTask == nil)
        #expect(!sut.workflowHistoryState.isLoading)
        #expect(sut.workflowRuns.map(\.id) == ["fresh"])
    }

}
