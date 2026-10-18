import Foundation
import MonitorCore
import PbUI

// MARK: - Execution groups

extension SidebarVM {
    /// Ownership is available from task metadata before the slower workflow poll arrives.
    /// Propagate it through follow-ups and spawned descendants without assuming list order.
    var workflowTaskOwners: [String: String] { indexedWorkflowOwners }

    func workflowChildren(_ runID: String) -> [TaskInfo] { indexedWorkflowChildren[runID] ?? [] }

    func groupConversations(_ group: ParallelGroup) -> [Conversation] {
        indexedGroupConversations[group.id] ?? group.conversations
    }

    func executionParent(of taskID: String) -> String? { indexedExecutionParents[taskID] }

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

}
