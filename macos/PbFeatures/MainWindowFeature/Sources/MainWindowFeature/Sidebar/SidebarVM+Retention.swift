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
            return .task(Lineage.conversationID(of: id, in: latestTasks))
        }
        if let siblings = lastKnownSiblingsByMember[id],
           let survivor = Lineage.oldestSurvivor(among: siblings, in: latestTasks) {
            return .task(Lineage.conversationID(of: survivor, in: latestTasks))
        }
        return .task(id)
    }

    /// Records every current conversation's member set against each of its own members (Review
    /// round 1, item 4), so a later id that disappears (retention) can still be resolved through a
    /// sibling that survives it. Walks the WHOLE tree via `flattened()` (Codex review round 1,
    /// finding 2) — not just the top-level roots in `sections.running`/`sections.recent` — so a
    /// NESTED conversation (one attached under another, e.g. `P → conv(A,B)`) is remembered too, and
    /// hands off correctly when its own first member (`A`) is pruned. Only `running`/`recent` —
    /// Parallel groups are unaffected by this feature (Review round 1, item 3) and keep no such
    /// history.
    func recordMembership(_ sections: ConversationSections) {
        for root in sections.running + sections.recent {
            for (node, _) in root.flattened() {
                let ids = Set(node.conversation.members.map(\.taskID))
                for id in ids { lastKnownSiblingsByMember[id] = ids }
            }
        }
    }

    /// Carries a collapsed conversation's state to its new identity when its own first member is
    /// pruned by retention: if a previously-collapsed id is no longer present at all, but one of its
    /// remembered siblings still is, the collapse moves to that conversation's current id — through
    /// the same deterministic `oldestSurvivor` rule `normalized(_:)` uses.
    func migrateCollapsedIDsForRetention() {
        // Snapshot first: this mutates `collapsedTaskIDs` inside the loop, which is unsafe to do
        // while iterating the live set directly.
        for oldID in Array(collapsedTaskIDs) where !latestTasks.contains(where: { $0.taskID == oldID }) {
            guard let siblings = lastKnownSiblingsByMember[oldID],
                  let survivor = Lineage.oldestSurvivor(among: siblings, in: latestTasks) else { continue }
            let newID = Lineage.conversationID(of: survivor, in: latestTasks)
            guard newID != oldID else { continue }
            collapsedTaskIDs.remove(oldID)
            collapsedTaskIDs.insert(newID)
        }
    }
}
