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

struct SidebarWorkflowRun {
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
    var workflowBuilderTaskIDs: Set<String> {
        Set(workflowRuns.filter { $0.raw["kind"]?.stringValue == "builder" }.flatMap { run in
            WorkflowJSON.objects(run.raw["activations"]).flatMap { activation in
                WorkflowJSON.objects(activation["tasks"]).compactMap { $0["task_id"]?.stringValue }
            }
        })
    }

    var savedWorkflows: [WorkflowRecord] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return workflowDefinitions.filter { record in
            query.isEmpty || "\(record.id) \(record.description)".lowercased().contains(query)
        }
    }

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

    func filteredWorkflowRuns() -> [SidebarWorkflowRun] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var runs = workflowRuns.filter { WorkflowRunIdentity.isValid($0.id) }
        let known = Set(runs.map(\.id))
        for task in latestTasks {
            guard let id = task.raw["workflow_run_id"]?.stringValue, WorkflowRunIdentity.isValid(id), !known.contains(id), !runs.contains(where: { $0.id == id }),
                  task.raw["workflow_builder"]?.boolValue != true else { continue }
            runs.append(SidebarWorkflowRun(raw: ["workflow_run_id": .string(id),
                "name": task.raw["workflow_name"] ?? .string("Workflow"),
                "status": task.raw["workflow_status"] ?? .string("running"),
                "settling": task.raw["workflow_settling"] ?? .bool(false),
                "repo_path": .string(task.repoPath),
                "created_at": .number(task.startedAt?.timeIntervalSince1970 ?? 0)]))
        }
        let matching = runs.filter { run in
            guard run.raw["kind"]?.stringValue != "builder" else { return false }
            let text = "\(run.name) \(run.id) \(run.raw["repo_path"]?.stringValue ?? "") \(run.raw["prompt"]?.stringValue ?? "")"
            let declaredBackends = Set(run.raw["backends"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let backends = workflowBackends(run.raw["definition"]?.objectValue ?? [:])
                .union(declaredBackends)
.union(workflowChildren(run.id).map(\.backend))
            return (query.isEmpty || text.lowercased().contains(query)) && (selectedBackend == "all" || backends.contains(selectedBackend))
        }
        var visible = Set(matching.map(\.id))
        for run in matching {
            var parent = run.parentRunID
            var visited: Set<String> = [run.id]
            while let id = parent, visited.insert(id).inserted, let ancestor = runs.first(where: { $0.id == id }) {
                visible.insert(id)
                parent = ancestor.parentRunID
            }
        }
        return runs.filter { visible.contains($0.id) }
    }

    func workflowTreeItems(_ run: SidebarWorkflowRun, depth: Int = 0, visited: Set<String> = []) -> [SidebarItem] {
        guard !visited.contains(run.id) else { return [] }
        let children = filteredWorkflowRuns().filter { $0.parentRunID == run.id }
        let expanded = expandedExecutionParents.contains("workflow:\(run.id)") || !searchQuery.isEmpty || selectedBackend != "all"
        let row = workflowRow(run, depth: depth, expanded: expanded)
        guard expanded else { return [.workflow(row)] }
        let tasks = workflowChildren(run.id)
        let shortcuts = children.enumerated().map { index, child in
            SidebarItem.workflowShortcut(workflowRow(child, depth: depth + 1, expanded: false, shortcut: true,
                guides: [index == children.count - 1 ? .last : .branch]), parentRunID: run.id)
        }
        return [.workflow(row)] + executionRows(tasks, depth: depth + 1, hasFollowingSiblings: !children.isEmpty) + shortcuts
    }

    private func workflowBackends(_ definition: [String: JSONValue]) -> Set<String> {
        let candidates = WorkflowJSON.objects(definition["nodes"]).compactMap { $0["agent"]?.objectValue }
            + [definition["orchestrator"]?.objectValue].compactMap(\.self)
        return Set(candidates.flatMap { candidate in
            [candidate["backend"]?.stringValue].compactMap(\.self)
                + WorkflowJSON.objects(candidate["fallbacks"]).compactMap { $0["backend"]?.stringValue }
        })
    }

    func workflowRow(_ run: SidebarWorkflowRun, depth: Int = 0, expanded: Bool? = nil, shortcut: Bool = false, guides: [TreeGuide] = []) -> TaskRowModel {
        let rawStatus = run.raw["status"]?.stringValue ?? "unknown"
        let specialStatus = ["paused", "needs_input", "needs_attention", "starting", "cancelling"].contains(rawStatus)
        let status: TaskStatus = run.raw["settling"]?.boolValue == true ? .other("Settling") : specialStatus
            ? .other(rawStatus.replacingOccurrences(of: "_", with: " ").capitalized) : TaskStatus(rawStatus)
        return TaskRowModel(id: run.id, backend: "workflow", title: run.name, status: status,
                            repoName: Format.repoName(run.raw["repo_path"]?.stringValue ?? ""), ageText: Format.age(run.startedAt),
                            detailLabel: shortcut ? "Child workflow" : nil,
                            indent: depth, subTaskSummary: run.raw["attention_reason"]?.stringValue, startedAt: run.startedAt,
                            hasChildren: !shortcut && (!workflowChildren(run.id).isEmpty || workflowRuns.contains { $0.parentRunID == run.id }),
                            isExpanded: expanded ?? expandedExecutionParents.contains("workflow:\(run.id)"), guides: guides)
    }
}
