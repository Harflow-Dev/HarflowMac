//
//  MainWindowCoordinator+Drafts.swift
//  MainWindowFeature
//

import Foundation
import MonitorCore

// MARK: - MainWindowCoordinator + drafts

/// Membership and reconciliation for `TaskDraftStore`. Everything here is draft ownership only: it decides which
/// stored draft a standalone task view shows and never feeds an action, an engine identity, Continue or routing.
extension MainWindowCoordinator {
    /// `id`'s conversation key (its normalised first member) with the ids of every member of that conversation, in
    /// one pass: orchestrator/session membership first, else the qualified continuation/parent components of
    /// `Lineage`, never `spawnedBy`. An unknown id is its own conversation. Draft retention uses the members only
    /// as ownership aliases, never for an action, engine identity, Continue or routing.
    func conversationKeyAndMembers(for id: String) -> (key: String, members: Set<String>) {
        let tasks = taskListRepository.tasks
        if let members = WorkflowOrchestratorConversation.members(containing: id, in: tasks), let first = members.first {
            return (first.taskID, Set(members.map(\.taskID)))
        }
        if let conversation = Lineage.conversation(containing: id, in: tasks) {
            return (conversation.id, Set(conversation.members.map(\.taskID)))
        }
        return (id, [id])
    }

    /// The draft home for a standalone task view of the conversation `key` (read-only: nothing is stored until the
    /// user types). `currentTaskID` is read at each edit to record which task the draft was written for.
    func draftMount(key: String, members: Set<String>, currentTaskID: @escaping () -> String) -> TaskDraftMount {
        draftStore.makeMount(key: key, members: members, partition: draftPartition(), currentTaskID: currentTaskID)
    }

    /// The draft home the builder would give `id`'s conversation right now.
    func draftMount(for id: String) -> TaskDraftMount {
        let (key, members) = conversationKeyAndMembers(for: id)
        return draftMount(key: key, members: members) { id }
    }

    /// The listing's member to conversation map for draft retention, rebuilt only when the listing differs from the
    /// last one used.
    func draftPartition() -> TaskDraftPartition {
        let tasks = taskListRepository.tasks
        if draftPartitionCache.tasks != tasks { draftPartitionCache = TaskDraftPartition(tasks: tasks) }
        return draftPartitionCache
    }

    /// Re-attaches stored drafts to the listing: aliases for continuations that appeared and members pruned,
    /// conflicts after a join, and live composers following a survivor. Skipped while no draft is stored or mounted.
    func reconcileDrafts() {
        guard !draftStore.isIdle else { return }
        draftStore.reconcile(partition: draftPartition())
    }
}
