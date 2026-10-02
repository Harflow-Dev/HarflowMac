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
}

struct SidebarWorkflowRun {
    let raw: [String: JSONValue]
    var id: String { raw["workflow_run_id"]?.stringValue ?? "" }
    var name: String { raw["name"]?.stringValue ?? "Workflow" }
    var startedAt: Date? { raw["created_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) }
    var isActive: Bool { ["starting", "running", "paused", "needs_attention", "cancelling"].contains(raw["status"]?.stringValue ?? "") }
}

extension SidebarVM {
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
                    workflowDefinitions = snapshot.definitions.map { WorkflowRecord(raw: $0) }
                    workflowRuns = snapshot.runs.map { SidebarWorkflowRun(raw: $0) }.filter { !$0.id.isEmpty }
                    workflowErrorMessage = nil
                    recompute()
                } catch {
                    guard let self, !Task.isCancelled, workflowGeneration == token else { return }
                    workflowErrorMessage = "Workflow list unavailable"
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stopWorkflowPolling() {
        workflowGeneration = UUID()
        workflowPoll?.cancel()
        workflowPoll = nil
    }

    func filteredWorkflowRuns() -> [SidebarWorkflowRun] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return workflowRuns.filter { run in
            let text = "\(run.name) \(run.id) \(run.raw["repo_path"]?.stringValue ?? "") \(run.raw["prompt"]?.stringValue ?? "")"
            let backends = workflowBackends(run.raw["definition"]?.objectValue ?? [:])
            return (query.isEmpty || text.lowercased().contains(query)) && (selectedBackend == "all" || backends.contains(selectedBackend))
        }
    }

    private func workflowBackends(_ definition: [String: JSONValue]) -> Set<String> {
        let candidates = WorkflowJSON.objects(definition["nodes"]).compactMap { $0["agent"]?.objectValue }
            + [definition["orchestrator"]?.objectValue].compactMap(\.self)
        return Set(candidates.flatMap { candidate in
            [candidate["backend"]?.stringValue].compactMap(\.self)
                + WorkflowJSON.objects(candidate["fallbacks"]).compactMap { $0["backend"]?.stringValue }
        })
    }

    func workflowRow(_ run: SidebarWorkflowRun) -> TaskRowModel {
        let rawStatus = run.raw["status"]?.stringValue ?? "unknown"
        let status: TaskStatus = ["paused", "needs_attention", "starting", "cancelling"].contains(rawStatus)
            ? .other(rawStatus.replacingOccurrences(of: "_", with: " ").capitalized) : TaskStatus(rawStatus)
        return TaskRowModel(id: run.id, backend: "workflow", title: run.name, status: status,
                            repoName: Format.repoName(run.raw["repo_path"]?.stringValue ?? ""), ageText: Format.age(run.startedAt),
                            subTaskSummary: run.raw["attention_reason"]?.stringValue, startedAt: run.startedAt)
    }
}
