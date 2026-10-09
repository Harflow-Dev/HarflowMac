import Foundation
import MonitorCore
import PbCommon
import PbUI

// MARK: - Sidebar Workflows presentation

extension SidebarPresentationBuilder {
    func computeFilteredWorkflowRuns() -> [SidebarWorkflowRun] {
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
            while let id = parent, visited.insert(id).inserted, let ancestor = indexedRuns[id] {
                visible.insert(id)
                parent = ancestor.parentRunID
            }
        }
        return runs.filter { visible.contains($0.id) }
    }

    func workflowTreeItems(_ run: SidebarWorkflowRun, depth: Int = 0, visited: Set<String> = []) -> [SidebarItem] {
        guard !visited.contains(run.id) else { return [] }
        let children = visibleChildren[run.id] ?? []
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
                            repoName: Format.repoName(run.raw["repo_path"]?.stringValue ?? ""), ageText: Format.age(run.startedAt, now: input.now),
                            detailLabel: shortcut ? "Child workflow" : nil,
                            indent: depth, subTaskSummary: run.raw["attention_reason"]?.stringValue, startedAt: run.startedAt,
                            hasChildren: !shortcut && (!workflowChildren(run.id).isEmpty || unfilteredChildRuns.contains(run.id)),
                            isExpanded: expanded ?? expandedExecutionParents.contains("workflow:\(run.id)"), guides: guides)
    }
}
