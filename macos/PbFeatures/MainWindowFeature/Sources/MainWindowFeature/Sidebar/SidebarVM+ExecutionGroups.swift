import Foundation
import MonitorCore
import PbUI

// MARK: - Execution groups

extension SidebarVM {
    /// Ownership is available from task metadata before the slower workflow poll arrives.
    /// Propagate it through follow-ups and spawned descendants without assuming list order.
    var workflowTaskOwners: [String: String] {
        var owners: [String: String] = [:]
        for run in workflowRuns {
            for activation in WorkflowJSON.objects(run.raw["activations"]) {
                for task in WorkflowJSON.objects(activation["tasks"]) {
                    if let id = task["task_id"]?.stringValue { owners[id] = run.id }
                }
            }
        }
        for task in latestTasks {
            if let runID = task.raw["workflow_run_id"]?.stringValue { owners[task.taskID] = runID }
        }
        var changed = true
        while changed {
            changed = false
            for task in latestTasks where owners[task.taskID] == nil {
                if let owner = [task.parentTaskID, task.spawnedBy].compactMap(\.self).compactMap({ owners[$0] }).first {
                    owners[task.taskID] = owner
                    changed = true
                }
            }
        }
        return owners
    }

    func workflowChildren(_ runID: String) -> [TaskInfo] {
        let owners = workflowTaskOwners
        return latestTasks.filter { owners[$0.taskID] == runID }.sorted(by: executionOrder)
    }

    func groupChildren(_ name: String) -> [TaskInfo] {
        let owners = workflowTaskOwners
        var ids = Set(latestTasks.filter { $0.group == name && owners[$0.taskID] == nil }.map(\.taskID))
        var changed = true
        while changed {
            changed = false
            for task in latestTasks where !ids.contains(task.taskID) && owners[task.taskID] == nil {
                if [task.parentTaskID, task.spawnedBy].compactMap(\.self).contains(where: ids.contains) {
                    ids.insert(task.taskID); changed = true
                }
            }
        }
        return latestTasks.filter { ids.contains($0.taskID) }.sorted(by: executionOrder)
    }

    func executionParent(of taskID: String) -> String? {
        if let owner = workflowTaskOwners[taskID] { return "workflow:\(owner)" }
        for group in Lineage.sections(latestTasks).parallel where group.total > 1 && groupChildren(group.name).contains(where: { $0.taskID == taskID }) {
            return group.id
        }
        return nil
    }

    func expandExecutionParent(of taskID: String) {
        if let parent = executionParent(of: taskID) { expandedExecutionParents.insert(parent) }
    }

    func isExecutionParentExpanded(_ id: String) -> Bool { expandedExecutionParents.contains(id) }

    func executionRows(_ tasks: [TaskInfo]) -> [SidebarItem] {
        tasks.enumerated().map { index, task in
            .task(TaskRowModel(id: task.taskID, backend: task.backend, title: useCase.title(task.taskID), status: task.status,
                               repoName: Format.repoName(task.repoPath), ageText: Format.age(task.startedAt), detailLabel: workflowChildLabel(task), indent: 1,
                               startedAt: task.startedAt, durationSeconds: task.durationSeconds,
                               guides: [index == tasks.count - 1 ? .last : .branch]))
        }
    }

    private func workflowChildLabel(_ task: TaskInfo) -> String? {
        for run in workflowRuns {
            for activation in WorkflowJSON.objects(run.raw["activations"]) {
                guard WorkflowJSON.objects(activation["tasks"]).contains(where: { $0["task_id"]?.stringValue == task.taskID }) else { continue }
                if activation["role"]?.stringValue == "orchestrator" { return "Orchestrator" }
                if let nodeID = activation["node_id"]?.stringValue {
                    return WorkflowJSON.nodes(run.raw["definition"]?.objectValue ?? [:]).first(where: { $0.id == nodeID })?.name ?? nodeID
                }
            }
        }
        return nil
    }

    private func executionOrder(_ left: TaskInfo, _ right: TaskInfo) -> Bool {
        if left.startedAt != right.startedAt { return (left.startedAt ?? .distantPast) < (right.startedAt ?? .distantPast) }
        return left.taskID < right.taskID
    }
}
