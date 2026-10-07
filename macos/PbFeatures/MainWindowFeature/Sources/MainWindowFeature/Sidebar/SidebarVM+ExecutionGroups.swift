import Foundation
import MonitorCore
import PbUI

// MARK: - Execution groups

extension SidebarVM {
    /// Ownership is available from task metadata before the slower workflow poll arrives.
    /// Propagate it through follow-ups and spawned descendants without assuming list order.
    var workflowTaskOwners: [String: String] {
        var owners: [String: String] = [:]
        for run in workflowRuns where WorkflowRunIdentity.isValid(run.id) {
            for activation in WorkflowJSON.objects(run.raw["activations"]) {
                for task in WorkflowJSON.objects(activation["tasks"]) {
                    if let id = task["task_id"]?.stringValue { owners[id] = run.id }
                }
            }
        }
        for task in latestTasks {
            if let runID = task.raw["workflow_run_id"]?.stringValue ?? task.raw["workflow_session_owner_run_id"]?.stringValue,
               WorkflowRunIdentity.isValid(runID) { owners[task.taskID] = runID }
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
        let transportIDs = Set(workflowRuns.flatMap { WorkflowJSON.objects($0.raw["activations"]) }
            .filter { $0["role"]?.stringValue == "native_control" }
            .flatMap { WorkflowJSON.objects($0["tasks"]).compactMap { $0["task_id"]?.stringValue } })
        let all = latestTasks.filter {
            owners[$0.taskID] == runID && !WorkflowNodePresentation.isNativeControl($0) && !transportIDs.contains($0.taskID)
        }
.sorted(by: executionOrder)
        var seen: Set<String> = []
        return all.compactMap { task in
            let members = WorkflowOrchestratorConversation.members(containing: task.taskID, in: all) ?? [task]
            guard let first = members.first, seen.insert(first.taskID).inserted else { return nil }
            return WorkflowOrchestratorConversation.representative(members)
        }
.sorted(by: executionOrder)
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

    func groupConversations(_ group: ParallelGroup) -> [Conversation] {
        WorkflowOrchestratorConversation.conversations(group.conversations.flatMap(\.members))
    }

    func executionParent(of taskID: String) -> String? {
        if let owner = workflowTaskOwners[taskID] { return "workflow:\(owner)" }
        for group in Lineage.sections(latestTasks).parallel where groupConversations(group).count > 1 {
            if groupChildren(group.name).contains(where: { $0.taskID == taskID }) { return group.id }
        }
        return nil
    }

    func expandExecutionParent(of taskID: String) {
        if let parent = executionParent(of: taskID) {
            expandedExecutionParents.insert(parent)
            var runID = workflowTaskOwners[taskID]
            var visited: Set<String> = []
            while let id = runID, visited.insert(id).inserted,
                  let parentID = workflowRuns.first(where: { $0.id == id })?.parentRunID {
                expandedExecutionParents.insert("workflow:\(parentID)")
                runID = parentID
            }
        }
    }

    func isExecutionParentExpanded(_ id: String) -> Bool { expandedExecutionParents.contains(id) }

    func executionRows(_ tasks: [TaskInfo], depth: Int = 1, hasFollowingSiblings: Bool = false) -> [SidebarItem] {
        let owners = workflowTaskOwners
        let rows = tasks.contains(where: { owners[$0.taskID] != nil }) ? tasks
            : WorkflowOrchestratorConversation.conversations(tasks).compactMap { WorkflowOrchestratorConversation.representative($0.members) }
        return rows.enumerated().map { index, task in
            .task(TaskRowModel(id: task.taskID, backend: task.backend, title: useCase.title(task.taskID), status: task.status,
                               repoName: Format.repoName(task.repoPath), ageText: Format.age(task.startedAt),
                               detailLabel: workflowChildLabel(task), indent: depth,
                               startedAt: task.startedAt, durationSeconds: task.durationSeconds,
                               guides: [index == rows.count - 1 && !hasFollowingSiblings ? .last : .branch]))
        }
    }

    private func workflowChildLabel(_ task: TaskInfo) -> String? {
        if task.raw["workflow_role"]?.stringValue == "orchestrator" { return "Orchestrator" }
        if let runID = task.raw["workflow_run_id"]?.stringValue, let nodeID = task.raw["workflow_node_id"]?.stringValue,
           let run = workflowRuns.first(where: { $0.id == runID }) {
            return run.raw["node_labels"]?[nodeID]?.stringValue
                ?? WorkflowJSON.nodes(run.raw["definition"]?.objectValue ?? [:]).first(where: { $0.id == nodeID })?.name ?? nodeID
        }
        for run in workflowRuns {
            for activation in WorkflowJSON.objects(run.raw["activations"]) {
                guard WorkflowJSON.objects(activation["tasks"]).contains(where: { $0["task_id"]?.stringValue == task.taskID }) else { continue }
                if activation["role"]?.stringValue == "orchestrator" { return "Orchestrator" }
                if let nodeID = activation["node_id"]?.stringValue {
                    return run.raw["node_labels"]?[nodeID]?.stringValue
                        ?? WorkflowJSON.nodes(run.raw["definition"]?.objectValue ?? [:]).first(where: { $0.id == nodeID })?.name ?? nodeID
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
