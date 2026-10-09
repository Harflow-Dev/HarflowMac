import Foundation
import Mockable
import MonitorCore
import PbCommon
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

extension SidebarVM {
    func didTapNewWorkflow() { routing.select(.newWorkflow(UUID())) }

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
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                    workflowDefinitions = snapshot.definitions.map { WorkflowRecord(raw: $0) }
                    mergeWorkflowHeaders(snapshot.runs, replacing: snapshot.page == nil)
                    if let page = snapshot.page { updateWorkflowHistory(page, advancing: false) }
                    await refreshChildInvocationHeaders()
                    workflowErrorMessage = nil
                    publishViewEvent(.incidentResolved(source: "workflow-list"))
                    await refreshLoadedWorkflowStatus(excluding: Set(snapshot.runs.compactMap { $0["workflow_run_id"]?.stringValue }))
                    guard !Task.isCancelled, workflowGeneration == token else { return }
                    recompute()
                } catch {
                    guard let self, !Task.isCancelled, workflowGeneration == token else { return }
                    workflowErrorMessage = "Workflow list unavailable: \((error as? ToolError)?.message ?? error.localizedDescription)"
                    publishWorkflowIncident(source: "workflow-list", message: workflowErrorMessage ?? "Workflow list unavailable")
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
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
