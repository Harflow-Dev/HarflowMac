import Foundation
import MonitorCore
import PbCommon
import PbUI

// MARK: - Sidebar ExecutionGroups presentation

extension SidebarPresentationBuilder {
    /// Ownership is available from task metadata before the slower workflow poll arrives.
    /// Propagate it through follow-ups and spawned descendants without assuming list order.
    var workflowTaskOwners: [String: String] { indexedOwners }

    func computeWorkflowTaskOwners() -> [String: String] {
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
            if Task.isCancelled { break }
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

    func workflowChildren(_ runID: String) -> [TaskInfo] { indexedChildren[runID] ?? [] }

    func groupChildren(_ name: String) -> [TaskInfo] {
        let owners = workflowTaskOwners
        var ids = Set(latestTasks.filter { $0.group == name && owners[$0.taskID] == nil }.map(\.taskID))
        var changed = true
        while changed {
            if Task.isCancelled { break }
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
        SidebarConversationGrouping(group.conversations.flatMap(\.members), fallbackToConversation: true).conversations
    }

    func executionParent(of taskID: String) -> String? { executionParents[taskID] }

    mutating func expandExecutionParent(of taskID: String) {
        if let parent = executionParent(of: taskID) {
            expandedExecutionParents.insert(parent)
            var runID = workflowTaskOwners[taskID]
            var visited: Set<String> = []
            while let id = runID, visited.insert(id).inserted,
                  let parentID = indexedRuns[id]?.parentRunID {
                expandedExecutionParents.insert("workflow:\(parentID)")
                runID = parentID
            }
        }
    }

    func isExecutionParentExpanded(_ id: String) -> Bool { expandedExecutionParents.contains(id) }

    func executionRows(_ tasks: [TaskInfo], depth: Int = 1, hasFollowingSiblings: Bool = false) -> [SidebarItem] {
        let owners = workflowTaskOwners
        let rows = tasks.contains(where: { owners[$0.taskID] != nil }) ? tasks
            : SidebarConversationGrouping(tasks, fallbackToConversation: true)
.conversations
                .compactMap { WorkflowOrchestratorConversation.representative($0.members) }
        return rows.enumerated().map { index, task in
            .task(TaskRowModel(id: task.taskID, backend: task.backend, title: title(task.taskID), status: task.status,
                               repoName: Format.repoName(task.repoPath), ageText: Format.age(task.startedAt, now: input.now),
                               detailLabel: workflowChildLabel(task), indent: depth,
                               startedAt: task.startedAt, durationSeconds: task.durationSeconds,
                               guides: [index == rows.count - 1 && !hasFollowingSiblings ? .last : .branch]))
        }
    }

    private func workflowChildLabel(_ task: TaskInfo) -> String? {
        if task.raw["workflow_role"]?.stringValue == "orchestrator" { return "Orchestrator" }
        if let runID = task.raw["workflow_run_id"]?.stringValue, let nodeID = task.raw["workflow_node_id"]?.stringValue,
           let run = indexedRuns[runID] {
            return run.raw["node_labels"]?[nodeID]?.stringValue
                ?? WorkflowJSON.nodes(run.raw["definition"]?.objectValue ?? [:]).first(where: { $0.id == nodeID })?.name ?? nodeID
        }
        return indexedLabels[task.taskID]
    }

    func executionOrder(_ left: TaskInfo, _ right: TaskInfo) -> Bool {
        if left.startedAt != right.startedAt { return (left.startedAt ?? .distantPast) < (right.startedAt ?? .distantPast) }
        return left.taskID < right.taskID
    }
}
