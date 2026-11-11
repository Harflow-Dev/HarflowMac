//
//  TaskDraftStore.swift
//  MainWindowFeature
//
//  Keeps a standalone task's unsent message across navigation that unmounts the task view. App-session only:
//  nothing is written to disk and nothing reaches the engine. The store hands a mounted composer one thing, a text
//  binding. Everything it knows about which conversation a draft belongs to ("known members") is draft ownership
//  only: it is read by resolution and reconciliation below and by nothing else, so it can never become an action
//  target, an engine identity, Continue proof or routing authority.
//

import Foundation
import MonitorCore
import Observation
import SwiftUI

// MARK: - TaskDraftCell

/// One draft's text. Only the mounted composer reads it, so typing invalidates nothing else. "Nonempty" means
/// `!text.isEmpty`: whitespace-only drafts keep their exact bytes (`MessageBoxView.canSubmit` still trims to send).
@MainActor
@Observable
final class TaskDraftCell {
    let id = UUID()
    /// Written only by the store, through a mount's binding, so its bookkeeping cannot be bypassed.
    fileprivate(set) var text = ""
}

// MARK: - TaskDraftPartition

/// One listing's member to conversation-key map, computed with the same membership rules as
/// `MainWindowCoordinator.normalisedConversationID(for:)`: orchestrator/session buckets first, else qualified
/// continuation/parent links (`Lineage`), never `spawnedBy`.
struct TaskDraftPartition {
    let tasks: [TaskInfo]
    private(set) var keyOfMember: [String: String] = [:]
    private(set) var membersOfKey: [String: Set<String>] = [:]

    static let empty = TaskDraftPartition(tasks: [])

    init(tasks: [TaskInfo]) {
        self.tasks = tasks
        for conversation in WorkflowOrchestratorConversation.conversations(tasks) {
            guard let key = conversation.members.first?.taskID else { continue }
            for member in conversation.members {
                if keyOfMember[member.taskID] == nil { keyOfMember[member.taskID] = key }
                membersOfKey[key, default: []].insert(member.taskID)
            }
        }
    }
}

// MARK: - TaskDraftStore

/// Coordinator-owned, deliberately not observable: every bookkeeping map is a plain stored property, so reading it
/// from a view builder or a listing callback invalidates nothing.
@MainActor
final class TaskDraftStore {
    private var cells: [UUID: TaskDraftCell] = [:]
    private var ownerTaskID: [UUID: String] = [:]
    private var knownMembers: [UUID: Set<String>] = [:]
    private var updatedAt: [UUID: Date] = [:]
    /// Conversation key -> the cell that conversation shows.
    private var activeCell: [String: UUID] = [:]
    /// Losers of a join: kept, never shown again automatically, never merged and never deleted.
    private var shadowed: Set<UUID> = []
    private var mounts: [WeakMount] = []
    /// The listing last seen by `makeMount` or `reconcile`; used only to judge whether an active cell is stale.
    private var lastPartition = TaskDraftPartition.empty
    private let clock: () -> Date

    private struct WeakMount {
        weak var mount: TaskDraftMount?
    }

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    // MARK: - Inspection

    /// Stored (nonempty) draft count, shadowed ones included.
    var storedCount: Int { cells.count }

    /// Whether `cell` lost a conflict and is kept hidden.
    func isShadowed(_ cell: TaskDraftCell) -> Bool { shadowed.contains(cell.id) }

    /// Whether `cell` is stored, i.e. nonempty and retained.
    func isStored(_ cell: TaskDraftCell) -> Bool { cells[cell.id] != nil }

    /// Whether a listing change or mounted composer still needs the store (nothing to reconcile otherwise).
    var isIdle: Bool { cells.isEmpty && !mounts.contains { $0.mount != nil } }

    // MARK: - Mounting

    /// A mount for a standalone task view: the cell its conversation shows (an unstored empty one when there is
    /// none), plus the live bookkeeping it needs to write back. Writes nothing observable: no cell is created,
    /// stored, shadowed or re-activated. With no stored draft the partition is not even built.
    func makeMount(key: String, members: Set<String>, partition: @autoclosure () -> TaskDraftPartition,
                   currentTaskID: @escaping () -> String) -> TaskDraftMount {
        var cell: TaskDraftCell?
        if !cells.isEmpty {
            let listing = partition()
            lastPartition = listing
            cell = resolve(key: key, members: members, partition: listing)
        }
        let mount = TaskDraftMount(store: self, cell: cell ?? TaskDraftCell(), key: key, members: members,
                                   currentTaskID: currentTaskID)
        mounts.removeAll { $0.mount == nil }
        mounts.append(WeakMount(mount: mount))
        return mount
    }

    // MARK: - Resolution

    /// The cell `key` shows, or `nil` for none. A pure read: no cell is created, stored, shadowed or re-activated.
    /// 1. The active cell, if it is still stored and still homed on `key`.
    /// 2. Otherwise the non-shadowed stored cells with a known member in `members` that are homed on `key`; one
    ///    wins by `preferred(_:members:)` (a join is only committed by `reconcile`).
    func resolve(key: String, members: Set<String>, partition: TaskDraftPartition) -> TaskDraftCell? {
        // A key the listing does not contain (a task opened before it was listed) is its own conversation.
        let unlisted = partition.keyOfMember[key] == nil ? key : nil
        if let id = activeCell[key], let cell = cells[id], !shadowed.contains(id),
           home(of: id, in: partition, unlisted: unlisted) == key {
            return cell
        }
        let claimable = cells.keys.filter { id in
            !shadowed.contains(id)
                && !(knownMembers[id] ?? []).isDisjoint(with: members)
                && home(of: id, in: partition, unlisted: unlisted) == key
        }
        guard let winner = preferred(claimable, members: members) else { return nil }
        return cells[winner]
    }

    /// The conversation key a stored draft is homed on: where its present known members live. When they live in
    /// several conversations (a branch split) the draft stays with the one holding its owner task, else the one
    /// holding the oldest surviving known member, the rule the sidebar and an open task view use to follow a pruned
    /// conversation. `nil` when none of its known members is in the listing.
    private func home(of id: UUID, in partition: TaskDraftPartition, unlisted: String? = nil) -> String? {
        guard let known = knownMembers[id] else { return nil }
        let keys = Set(known.compactMap { partition.keyOfMember[$0] ?? ($0 == unlisted ? unlisted : nil) })
        switch keys.count {
        case 0: return nil
        case 1: return keys.first
        default:
            if let owner = ownerTaskID[id], let key = partition.keyOfMember[owner] { return key }
            return Lineage.oldestSurvivor(among: known, in: partition.tasks).flatMap { partition.keyOfMember[$0] }
        }
    }

    /// Among competing drafts: one whose owner task is in `members`, then the most recently edited, then the id
    /// (so the choice is deterministic).
    private func preferred(_ ids: [UUID], members: Set<String>) -> UUID? {
        ids.min { lhs, rhs in
            let lhsOwned = ownerTaskID[lhs].map(members.contains) ?? false
            let rhsOwned = ownerTaskID[rhs].map(members.contains) ?? false
            if lhsOwned != rhsOwned { return lhsOwned }
            let lhsDate = updatedAt[lhs] ?? .distantPast
            let rhsDate = updatedAt[rhs] ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.uuidString < rhs.uuidString
        }
    }

    // MARK: - Writes

    /// The one write path (through a mount's binding). Empty to nonempty stores the cell; every edit refreshes the
    /// owner (the mounted view model's live current task) and the edit time; nonempty to empty drops the cell.
    fileprivate func write(_ value: String, to cell: TaskDraftCell, through mount: TaskDraftMount) {
        guard cell.text != value else { return }
        cell.text = value
        let id = cell.id
        if value.isEmpty {
            guard cells.removeValue(forKey: id) != nil else { return }
            ownerTaskID[id] = nil
            knownMembers[id] = nil
            updatedAt[id] = nil
            shadowed.remove(id)
            activeCell = activeCell.filter { $0.value != id }
            return
        }
        if cells[id] == nil {
            cells[id] = cell
            knownMembers[id] = mount.members
        }
        if !shadowed.contains(id), isActiveStale(for: mount.key) { activeCell[mount.key] = id }
        knownMembers[id, default: []].formUnion(mount.members)
        ownerTaskID[id] = mount.currentTaskID()
        updatedAt[id] = clock()
    }

    /// Whether `key` has no usable active cell: none, one no longer stored, shadowed, or homed elsewhere.
    private func isActiveStale(for key: String) -> Bool {
        guard let id = activeCell[key], cells[id] != nil, !shadowed.contains(id) else { return true }
        let unlisted = lastPartition.keyOfMember[key] == nil ? key : nil
        return home(of: id, in: lastPartition, unlisted: unlisted) != key
    }

    // MARK: - Reconciliation

    /// Run on every listing change, the only place ownership and conflicts are decided. For each stored cell it
    /// unions its known members with the current members of the conversation it is homed on (continuations that
    /// appeared while the task was closed, later prunes), then recomputes the active cell per key: where two or
    /// more non-shadowed drafts are now homed on one key (a join) the preferred one stays and the others are
    /// shadowed. Finally it refreshes live mounts so a mounted composer follows a survivor.
    func reconcile(partition: TaskDraftPartition) {
        var claimants: [String: [UUID]] = [:]
        for id in cells.keys where !shadowed.contains(id) {
            guard let key = home(of: id, in: partition) else { continue }
            knownMembers[id, default: []].formUnion(partition.membersOfKey[key] ?? [])
            claimants[key, default: []].append(id)
        }
        var active: [String: UUID] = [:]
        for (key, ids) in claimants {
            let members = partition.membersOfKey[key] ?? []
            guard let winner = preferred(ids, members: members) else { continue }
            for id in ids where id != winner { shadowed.insert(id) }
            active[key] = winner
        }
        activeCell = active
        lastPartition = partition
        mounts.removeAll { $0.mount == nil }
        for entry in mounts { if let mount = entry.mount { follow(mount, partition: partition) } }
    }

    /// Moves a live mount with the conversation its view model follows: the oldest surviving member of the mount's
    /// current membership (the open task view's rule). The mount's membership is replaced from the listing, never
    /// accumulated. A mount never stays bound to a stored draft that is shadowed or homed on another conversation:
    /// it rebinds to its own conversation's active cell, else a fresh empty one, so the draft stays (and appears)
    /// with its home. An unstored empty cell rebinds only to an active cell.
    private func follow(_ mount: TaskDraftMount, partition: TaskDraftPartition) {
        guard let survivor = Lineage.oldestSurvivor(among: mount.members, in: partition.tasks),
              let liveKey = partition.keyOfMember[survivor] else { return }
        mount.key = liveKey
        mount.members = partition.membersOfKey[liveKey] ?? [survivor]
        let current = mount.cell
        let active = activeCell[liveKey].flatMap { cells[$0] }
        if cells[current.id] != nil {
            let belongsHere = !shadowed.contains(current.id)
                && [liveKey, nil].contains(home(of: current.id, in: partition))
            if !belongsHere { mount.cell = active ?? TaskDraftCell() }
        } else if let active, active !== current {
            mount.cell = active
        }
    }
}

// MARK: - TaskDraftMount

/// What one mounted standalone composer holds: the cell it currently edits and its current membership, replaced
/// from the listing on each reconcile (never the stored draft's historical aliases). The cell is observed (rebinding
/// re-renders only the composer); everything else is not, and is invisible outside this file.
@MainActor
@Observable
final class TaskDraftMount {
    fileprivate(set) var cell: TaskDraftCell
    @ObservationIgnored fileprivate var key: String
    @ObservationIgnored fileprivate var members: Set<String>
    @ObservationIgnored fileprivate let currentTaskID: () -> String
    @ObservationIgnored private let store: TaskDraftStore

    fileprivate init(store: TaskDraftStore, cell: TaskDraftCell, key: String, members: Set<String>,
                     currentTaskID: @escaping () -> String) {
        self.store = store
        self.cell = cell
        self.key = key
        self.members = members
        self.currentTaskID = currentTaskID
    }

    /// The composer's text. Writes go through the store; nothing else is exposed.
    var text: Binding<String> {
        Binding(get: { self.cell.text }, set: { self.store.write($0, to: self.cell, through: self) })
    }

    #if DEBUG
    /// Test-only views of the live conversation key and membership.
    var testingKey: String { key }
    var testingMembers: Set<String> { members }
    #endif
}
