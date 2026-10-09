//
//  SidebarVM+Retention.swift
//  MainWindowFeature
//
//  Split out of SidebarVM.swift purely to keep that file under the swiftlint length budget — same
//  VM, same behaviour. Monitor piece 7, Review round 1 item 4's "retention while open": a
//  conversation's identity is its first member's id, so a background retention sweep that prunes
//  that specific record (while the conversation is still selected/collapsed in the sidebar) would
//  otherwise make an open, still-live conversation vanish from underneath the person looking at it.
//

import Foundation
import MonitorCore
import PbCommon

extension SidebarVM {

    // MARK: - Selection normalisation (Review round 1, item 5)

    /// Maps a `.task(id)` destination to the conversation it belongs to — `id` may be ANY member
    /// (a URL, notification, breadcrumb, menu-bar, or Parallel "open task" selection), while the
    /// sidebar's own rows are always tagged by the conversation's FIRST id. `.group`/`nil` pass
    /// through unchanged.
    ///
    /// Retention while open (Review round 1, item 4): when `id` itself is no longer in
    /// `latestTasks` at all (its own record was pruned), falls back to `lastKnownSiblingsByMember`
    /// to find a member that used to share its conversation and is STILL present, then resolves
    /// through that survivor — so a selection on a since-pruned id still highlights the row the
    /// conversation now shows under, instead of resolving to a dead id nothing displays. The
    /// survivor itself is picked by `Lineage.oldestSurvivor(among:in:)` (Codex review round 1,
    /// finding 3) — the SAME deterministic rule `TaskDetailVM` uses, never `Set.first` (no defined
    /// order) — so a branching prune (A resumed to both B and C, then A itself pruned) resolves to
    /// the same id on both screens. `private` is file-scoped in Swift, and
    /// `recompute()`/`didAppear()`/`subscribeIfNeeded()` live in `SidebarVM.swift` — hence no access
    /// modifier (internal), not `private`, on this and the other cross-file members below.
    func normalized(_ destination: MonitorDestination?) -> MonitorDestination? {
        guard case .task(let id) = destination else { return destination }
        if latestTasks.contains(where: { $0.taskID == id }) {
            if executionParent(of: id) != nil {
                expandExecutionParent(of: id)
                return .task(indexedRepresentatives[id]
                    ?? (workflowTaskOwners[id] == nil ? conversationIndex.conversationID(of: id) : id))
            }
            return .task(conversationIndex.conversationID(of: id))
        }
        if let siblings = lastKnownSiblingsByMember[id],
           let survivor = Lineage.oldestSurvivor(among: siblings, in: latestTasks) {
            return .task(conversationIndex.conversationID(of: survivor))
        }
        return .task(id)
    }

}
