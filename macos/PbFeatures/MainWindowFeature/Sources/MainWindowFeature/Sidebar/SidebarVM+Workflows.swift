import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI

// MARK: - SidebarWorkflowUseCase

@Mockable
@MainActor
protocol SidebarWorkflowUseCase: Sendable {
    func workflowSnapshot() async throws -> SidebarWorkflowSnapshot
}

struct SidebarWorkflowSnapshot: Sendable {
    let definitions: [[String: JSONValue]]
    let runs: [[String: JSONValue]]
    let page: HistoryPage?
    let catalogState: CatalogState
    init(definitions: [[String: JSONValue]], runs: [[String: JSONValue]], page: HistoryPage? = nil, catalogState: CatalogState = CatalogState(raw: [:])) {
        self.definitions = definitions
        self.runs = runs
        self.page = page
        self.catalogState = catalogState
    }
}

struct SidebarWorkflowRun: Equatable, Sendable {
    let raw: [String: JSONValue]
    var id: String { raw["workflow_run_id"]?.stringValue ?? "" }
    var name: String { raw["name"]?.stringValue ?? "Workflow" }
    var parentRunID: String? { raw["parent_workflow_run_id"]?.stringValue ?? raw["parent_link"]?["workflow_run_id"]?.stringValue }
    var startedAt: Date? { raw["created_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) }
    /// The persisted run update reflects continuation and completion of an existing invocation.
    var latestRunAt: Date? {
        [startedAt, raw["updated_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:))].compactMap(\.self).max()
    }

    var isActive: Bool {
        raw["settling"]?.boolValue == true
            || ["starting", "running", "paused", "needs_input", "needs_attention", "cancelling"].contains(raw["status"]?.stringValue ?? "")
    }
}

/// The complete recompute input the workflow poll owns — compared before/after each pass so an
/// unchanged poll (same definitions, same run headers, same loaded-workflow status, same failure
/// state) skips the recompute it would otherwise run every 2 s.
struct SidebarWorkflowPollState: Equatable {
    let definitions: [WorkflowRecord]
    let runs: [SidebarWorkflowRun]
    let history: HistoryLoadingState
    let errorMessage: String?
}

extension SidebarVM {
    func didTapNewWorkflow() { routing.select(.newWorkflow(UUID())) }

    /// The workflow poll's own presentation state, for the before/after comparison.
    var workflowPollState: SidebarWorkflowPollState {
        SidebarWorkflowPollState(definitions: workflowDefinitions, runs: workflowRuns,
                                history: workflowHistoryState, errorMessage: workflowErrorMessage)
    }

    /// One workflow-poll interval through the seams: the 2 s wait runs on the scheduler so tests
    /// fire it directly, and a hidden window parks in `waitForMainWindowVisible()` instead — the
    /// showing window wakes the loop, and the pass that follows is the immediate refresh on show.
    func waitWorkflowPollInterval() async throws {
        if clock.visibility.mainWindowVisible {
            try await clock.scheduler.wait(for: 2)
        } else {
            await clock.visibility.waitForMainWindowVisible()
            try Task.checkCancellation()
        }
    }

    /// One poll interval; false once the surrounding task is cancelled.
    func waitOrStop() async -> Bool {
        do { try await waitWorkflowPollInterval() } catch { return false }
        return true
    }

    /// Applies one ready snapshot and its dependent reads, recomputing only when the poll's
    /// complete input changed. False when the poll was superseded mid-way.
    func applyWorkflowSnapshot(_ snapshot: SidebarWorkflowSnapshot, token: UUID) async -> Bool {
        let before = workflowPollState
        workflowDefinitions = snapshot.definitions.map { WorkflowRecord(raw: $0) }
        mergeWorkflowHeaders(snapshot.runs, replacing: snapshot.page == nil)
        if let page = snapshot.page { updateWorkflowHistory(page, advancing: false) }
        await refreshChildInvocationHeaders()
        workflowErrorMessage = nil
        publishViewEvent(.incidentResolved(source: "workflow-list"))
        await refreshLoadedWorkflowStatus(excluding: Set(snapshot.runs.compactMap { $0["workflow_run_id"]?.stringValue }))
        guard !Task.isCancelled, workflowGeneration == token else { return false }
        if workflowPollState != before { recompute() }
        return true
    }

    func startWorkflowPolling() {
        guard workflowPoll == nil, let workflowUseCase else { return }
        let token = UUID()
        workflowGeneration = token
        workflowPoll = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let snapshot = try await workflowUseCase.workflowSnapshot()
                    guard let self, !Task.isCancelled, workflowGeneration == token else { return }
                    if !snapshot.catalogState.isReady {
                        if snapshot.catalogState.status == .blocked {
                            workflowErrorMessage = snapshot.catalogState.reason ?? "Workflow catalog is blocked."
                            publishWorkflowIncident(source: "workflow-list", message: workflowErrorMessage ?? "Workflow list unavailable")
                        }
                        if await waitOrStop() { continue }
                        return
                    }
                    guard await applyWorkflowSnapshot(snapshot, token: token) else { return }
                } catch {
                    guard let self, !Task.isCancelled, workflowGeneration == token else { return }
                    workflowErrorMessage = "Workflow list unavailable: \((error as? ToolError)?.message ?? error.localizedDescription)"
                    publishWorkflowIncident(source: "workflow-list", message: workflowErrorMessage ?? "Workflow list unavailable")
                }
                guard let self, await waitOrStop() else { return }
            }
        }
    }

    func publishWorkflowIncident(source: String, message: String) {
        publishViewEvent(.incident(source: source, message: message,
                                  retry: AlertAction(title: "Refresh workflows") { [weak self] in
            self?.stopWorkflowPolling()
            self?.startWorkflowPolling()
        }))
    }

    func stopWorkflowPolling() {
        workflowGeneration = UUID()
        workflowPoll?.cancel()
        workflowPoll = nil
        // Paging belongs to this polling generation; a stale response must not retain admission.
        workflowHistoryLoadTask?.cancel()
        workflowHistoryLoadTask = nil
        workflowHistoryRequestedCursor = nil
        workflowHistoryState.isLoading = false
    }

    static func invocationHeaders(parent: SidebarWorkflowRun, cachedDetails: [String: JSONValue]? = nil) -> [[String: JSONValue]] {
        // Full details enrich existing invocations, while newer compact headers can introduce
        // children launched since that snapshot. Neither source may hide the other's IDs.
        let sources = cachedDetails.map { [$0, parent.raw] } ?? [parent.raw]
        let references = sources.flatMap { raw in
            let expanded = WorkflowJSON.objects(raw["activations"]).compactMap { activation -> [String: JSONValue]? in
                guard let invocation = activation["invocation"]?.objectValue else { return nil }
                return ["child_workflow_run_id": invocation["child_workflow_run_id"] ?? .null,
                    "execution_id": activation["id"] ?? .null, "name": invocation["workflow_name"] ?? .string("Child workflow")]
            }
            return expanded + WorkflowJSON.objects(raw["child_invocations"])
        }
        var seen: Set<String> = []
        return references.compactMap { reference in
            guard let id = reference["child_workflow_run_id"]?.stringValue, WorkflowRunIdentity.isValid(id), seen.insert(id).inserted else { return nil }
            return ["workflow_run_id": .string(id), "name": reference["name"] ?? .string("Child workflow"),
                "status": .string("unknown"), "invocation_placeholder": .bool(true),
                "parent_workflow_run_id": .string(parent.id), "parent_link": .object([
                    "workflow_run_id": .string(parent.id), "execution_id": reference["execution_id"] ?? .null])]
        }
    }

    func refreshChildInvocationHeaders() async {
        let generation = workflowGeneration
        let known = Set(workflowRuns.map(\.id))
        let missing = workflowRuns.flatMap { run in
            Self.invocationHeaders(parent: run, cachedDetails: invocationDetails(run.id))
        }
.filter { !known.contains($0["workflow_run_id"]?.stringValue ?? "") }
        mergeWorkflowHeaders(missing)
        guard let history = historyUseCase else { return }
        let ids = workflowRuns.filter { $0.raw["invocation_placeholder"]?.boolValue == true }.map(\.id).sorted()
        guard !ids.isEmpty else { childInvocationRefreshOffset = 0; return }
        let offset = childInvocationRefreshOffset % ids.count
        let batch = Array((Array(ids[offset...]) + Array(ids[..<offset])).prefix(100))
        childInvocationRefreshOffset = (offset + batch.count) % ids.count
        do {
            let page = try await history.workflowBatch(runIDs: batch)
            guard !Task.isCancelled, workflowGeneration == generation else { return }
            if page.catalogState.isReady {
                mergeWorkflowHeaders(page.items + page.relatedHeaders)
                publishViewEvent(.incidentResolved(source: "workflow-child-status"))
            }
        } catch {
            guard !Task.isCancelled, workflowGeneration == generation else { return }
            // Keep unknown references selectable while bounded child header resolution retries.
            publishWorkflowIncident(source: "workflow-child-status", message: "Child workflow status unavailable: \(error.localizedDescription)")
        }
    }

}
