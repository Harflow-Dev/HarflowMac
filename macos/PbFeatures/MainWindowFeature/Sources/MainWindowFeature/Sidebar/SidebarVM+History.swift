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

    /// A viewport measurement, rather than row appearance, grants one automatic page request.
    func didChangeHistoryBottomVisibility(_ visible: Bool, revision: Int) {
        historyViewportRevision = revision
        historyBottomVisible = visible
        continueVisibleHistoryLoading()
    }

    func continueVisibleHistoryLoading() {
        guard presentationEnabled, historyBottomVisible, historyViewportRevision == historyPresentationRevision,
              pendingPresentationInput == nil, activePresentationInput == nil else { return }
        let tasksReady = canAutomaticallyLoad(taskHistoryState, lastCursor: taskHistoryRequestedCursor)
        let workflowsReady = canAutomaticallyLoad(workflowHistoryState, lastCursor: workflowHistoryRequestedCursor)
        guard tasksReady || workflowsReady else { return }
        // New rows invalidate this viewport measurement. A subsequent layout must grant another.
        historyBottomVisible = false
        if tasksReady { loadMoreTasks(automatic: true) }
        if workflowsReady { loadMoreWorkflows(automatic: true) }
    }

    private func canAutomaticallyLoad(_ state: HistoryLoadingState, lastCursor: String?) -> Bool {
        state.catalogState.isReady && state.hasMore && state.nextCursor != nil
            && state.nextCursor != lastCursor && !state.isLoading && state.error == nil
            && !state.bootstrapPending && !state.authorityIncomplete
    }

    func didTapLoadMoreTasks() { loadMoreTasks(automatic: false) }

    private func loadMoreTasks(automatic: Bool) {
        guard taskHistoryLoadTask == nil, !taskHistoryState.isLoading, let history = historyUseCase else { return }
        let epoch = presentationEpoch
        if automatic { taskHistoryRequestedCursor = taskHistoryState.nextCursor }
        taskHistoryLoadTask = Task { [weak self] in
            await history.loadMoreTaskHistory()
            guard let self, !Task.isCancelled, presentationEpoch == epoch else { return }
            taskHistoryLoadTask = nil
            recompute()
        }
    }

    func didTapLoadMoreWorkflows() { loadMoreWorkflows(automatic: false) }

    private func loadMoreWorkflows(automatic: Bool) {
        guard workflowHistoryLoadTask == nil, !workflowHistoryState.isLoading, let history = historyUseCase else { return }
        let token = workflowGeneration
        let epoch = presentationEpoch
        let cursor = workflowHistoryState.nextCursor
        if automatic { workflowHistoryRequestedCursor = cursor }
        workflowHistoryState.isLoading = true
        workflowHistoryState.error = nil
        workflowHistoryLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await history.workflowPage(cursor: cursor, relatedRunID: nil)
                guard !Task.isCancelled, workflowGeneration == token, presentationEpoch == epoch else { return }
                // Publish preparation/blocked diagnostics too, without advancing an opaque cursor.
                updateWorkflowHistory(page, advancing: true)
                if page.catalogState.isReady {
                    publishViewEvent(.incidentResolved(source: "workflow-history"))
                    mergeWorkflowHeaders(page.items + page.relatedHeaders)
                }
            } catch {
                guard !Task.isCancelled, workflowGeneration == token, presentationEpoch == epoch else { return }
                publishViewEvent(.incident(source: "workflow-history", message: (error as? ToolError)?.message ?? error.localizedDescription,
                    retry: AlertAction(title: "Refresh history") { [weak self] in self?.didTapLoadMoreWorkflows() }))
                workflowHistoryState.error = error as? ToolError ?? .unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: String(describing: error))
            }
            workflowHistoryState.isLoading = false
            workflowHistoryLoadTask = nil
            recompute()
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
