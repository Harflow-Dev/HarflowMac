import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbCommon
import PbCommonTestMock
import PbRepository
import PbTestUtilities
import Testing

// MARK: - SidebarSelectionReplayTests

@MainActor @Suite struct SidebarSelectionReplayTests {
    @Test func givenSelectedUnloadedWorkflow_whenInitialStateReplays_thenLookupRunsOnceAndNewSelectionStillResolves() async throws {
        // given
        let harness = SidebarVMTests().makeSUT()
        let routing = MainWindowCoordinator(parent: MockCoordinator())
        routing.selection = .workflowRun("initial-run")
        let history = HeldSidebarHistory()
        let vm = SidebarVM(useCase: harness.useCase, routing: routing, historyUseCase: history)
        defer { history.release(); vm.didDisappear() }
        // when — keep lookups suspended so the initial replay cannot be masked by a cached header.
        vm.didAppear()
        await vm.waitForPresentation()
        await waitUntil { history.requests.contains("initial-run") }
        routing.selection = .workflowRun("next-run")
        await waitUntil { history.requests.contains("next-run") }
        // then — the later delivery proves the initial replay was processed on the same queue.
        #expect(history.requests.filter { $0 == "initial-run" }.count == 1)
        #expect(history.requests.filter { $0 == "next-run" }.count == 1)
        #expect(vm.selection == .workflowRun("next-run"))
    }
}

// MARK: - HeldSidebarHistory

@MainActor private final class HeldSidebarHistory: SidebarHistoryUseCase {
    var requests: [String] = []
    private var pending: [CheckedContinuation<HistoryPage, any Error>] = []

    func taskHistoryStatePublisher() -> AnyPublisher<HistoryLoadingState, Never> { Just(HistoryLoadingState()).eraseToAnyPublisher() }
    func loadMoreTaskHistory() async {}
    func resolveTask(_: String) async {}
    func workflowBatch(runIDs _: [String]) async throws -> HistoryPage { page() }

    func workflowPage(cursor _: String?, relatedRunID: String?) async throws -> HistoryPage {
        requests.append(relatedRunID ?? "")
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func release() {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: page()) }
    }

    private func page() -> HistoryPage {
        HistoryPage(raw: ["items": .array([]), "next_cursor": .null, "has_more": .bool(false),
                          "bootstrap_pending": .bool(false)])!
    }
}
