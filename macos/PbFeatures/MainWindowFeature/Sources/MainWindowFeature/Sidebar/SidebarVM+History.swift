import Combine
import Foundation
import MonitorCore
import PbCommon
import PbRepository

/// Optional paging seam keeps preview and legacy use cases independent of catalog storage.
@MainActor
protocol SidebarHistoryUseCase {
    func taskHistoryStatePublisher() -> AnyPublisher<HistoryLoadingState, Never>
    func loadMoreTaskHistory() async
    func resolveTask(_ id: String) async
    func workflowBatch(runIDs: [String]) async throws -> HistoryPage
    func workflowPage(cursor: String?, relatedRunID: String?) async throws -> HistoryPage
}

extension SidebarVM {
    func requestWorkflowReveal(_ destination: MonitorDestination?) {
        if case .workflowRun(let id) = destination { pendingWorkflowRevealID = id } else { pendingWorkflowRevealID = nil }
    }

    func revealWorkflowAncestors() {
        guard let id = pendingWorkflowRevealID else { return }
        var current = id
        var visited: Set<String> = []
        while visited.insert(current).inserted {
            guard let run = workflowRuns.first(where: { $0.id == current }) else { return }
            guard let parent = run.parentRunID else { pendingWorkflowRevealID = nil; return }
            expandedExecutionParents.insert("workflow:\(parent)")
            current = parent
        }
        pendingWorkflowRevealID = nil
    }

    func refreshLoadedWorkflowStatus(excluding ids: Set<String>) async {
        guard let history = historyUseCase else { return }
        let active = workflowRuns.filter { $0.isActive && !ids.contains($0.id) }.map(\.id).sorted()
        guard !active.isEmpty else { workflowRefreshOffset = 0; publishViewEvent(.incidentResolved(source: "workflow-status")); return }
        let offset = workflowRefreshOffset % active.count
        let batch = Array((Array(active[offset...]) + Array(active[..<offset])).prefix(100))
        workflowRefreshOffset = (offset + batch.count) % active.count
        do {
            let page = try await history.workflowBatch(runIDs: batch)
            guard page.catalogState.isReady else { return }
            publishViewEvent(.incidentResolved(source: "workflow-status"))
            mergeWorkflowHeaders(page.items + page.relatedHeaders)
        } catch {
            workflowErrorMessage = "Workflow status update unavailable: \((error as? ToolError)?.message ?? error.localizedDescription)"
            publishWorkflowIncident(source: "workflow-status", message: workflowErrorMessage ?? "Workflow status unavailable")
        }
    }

    func subscribeToHistory() {
        guard let history = historyUseCase else { return }
        history.taskHistoryStatePublisher()
.receive(on: DispatchQueue.main)
.sink { [weak self] state in
            self?.taskHistoryState = state
        }
.store(in: &cancellables)
    }

    func didTapLoadMoreTasks() {
        guard !taskHistoryState.isLoading, let history = historyUseCase else { return }
        Task { await history.loadMoreTaskHistory() }
    }

    func didTapLoadMoreWorkflows() {
        guard !workflowHistoryState.isLoading, let history = historyUseCase else { return }
        let token = workflowGeneration
        workflowHistoryState.isLoading = true
        workflowHistoryState.error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await history.workflowPage(cursor: workflowHistoryState.nextCursor, relatedRunID: nil)
                guard !Task.isCancelled, workflowGeneration == token else { return }
                guard page.catalogState.isReady else { workflowHistoryState.isLoading = false; return }
                publishViewEvent(.incidentResolved(source: "workflow-history"))
                mergeWorkflowHeaders(page.items + page.relatedHeaders)
                updateWorkflowHistory(page, advancing: true)
                recompute()
            } catch {
                publishViewEvent(.incident(source: "workflow-history", message: (error as? ToolError)?.message ?? error.localizedDescription,
                    retry: AlertAction(title: "Refresh history") { [weak self] in self?.didTapLoadMoreWorkflows() }))
                workflowHistoryState.error = error as? ToolError ?? .unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: String(describing: error))
            }
            workflowHistoryState.isLoading = false
        }
    }

    func mergeWorkflowHeaders(_ headers: [[String: JSONValue]], replacing: Bool = false) {
        var indexed = replacing ? [:] : Dictionary(workflowRuns.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for raw in headers {
            let run = SidebarWorkflowRun(raw: raw)
            if WorkflowRunIdentity.isValid(run.id) { indexed[run.id] = run }
        }
        workflowRuns = indexed.values.sorted {
            let lhs = $0.startedAt ?? .distantPast
            let rhs = $1.startedAt ?? .distantPast
            return lhs == rhs ? $0.id > $1.id : lhs > rhs
        }
    }

    func updateWorkflowHistory(_ page: HistoryPage, advancing: Bool) {
        workflowHistoryState.catalogState = page.catalogState
        guard page.catalogState.isReady else { return }
        if advancing || !workflowHistoryInitialized {
            workflowHistoryState.nextCursor = page.nextCursor
            workflowHistoryState.hasMore = page.hasMore
        }
        if !page.bootstrapPending { workflowHistoryInitialized = true }
        workflowHistoryState.bootstrapPending = page.bootstrapPending
        workflowHistoryState.historyIncomplete = page.historyIncomplete
        workflowHistoryState.authorityIncomplete = page.authorityIncomplete
        workflowHistoryState.error = nil
    }

    func resolveUnloadedSelection(_ destination: MonitorDestination?) {
        guard let history = historyUseCase else { return }
        Task { [weak self] in
            switch destination {
            case .task(let id): await history.resolveTask(id)
            case .workflowRun(let id):
                guard let self, !workflowRuns.contains(where: { $0.id == id }) else { return }
                do {
                    let page = try await history.workflowPage(cursor: nil, relatedRunID: id)
                    guard page.catalogState.isReady else { return }
                    publishViewEvent(.incidentResolved(source: "workflow-lookup"))
                    mergeWorkflowHeaders(page.items + page.relatedHeaders)
                    recompute()
                } catch {
                    workflowErrorMessage = "Workflow lookup unavailable: \((error as? ToolError)?.message ?? error.localizedDescription)"
                    publishViewEvent(.incident(source: "workflow-lookup", message: workflowErrorMessage ?? "Workflow lookup unavailable",
                        retry: AlertAction(title: "Retry workflow lookup") { [weak self] in self?.resolveUnloadedSelection(.workflowRun(id)) }))
                }
            default: break
            }
        }
    }
}
