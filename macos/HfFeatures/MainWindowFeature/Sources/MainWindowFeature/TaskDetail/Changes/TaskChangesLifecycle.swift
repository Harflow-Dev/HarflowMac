//
//  TaskChangesLifecycle.swift
//  MainWindowFeature
//
//  The bookkeeping of the Changes tab's reads: which read is current, whether one is owed, and how long a settling
//  capture has been re-read. Plain values owned by `TaskDetailVM`; nothing here renders.
//

import Foundation
import MonitorCore

// MARK: - TaskChangesFence

/// The generation a read must still match, readable from the repository's `@Sendable` fence closure on any thread.
/// A lock guards it, as `EventStreamRepositoryImpl` guards its own shared state.
final class TaskChangesFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    /// Makes `generation` the only current one.
    func advance(to generation: UInt64) {
        lock.withLock { current = generation }
    }

    /// Whether `generation` is still the current one.
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { current == generation }
    }
}

// MARK: - TaskChangesLifecycle

/// Everything the view model remembers about reading stored changes for the shown member.
struct TaskChangesLifecycle {
    /// Seconds before the first re-read of a settling capture, measured from its first settling result.
    static let firstSettlingDelay: TimeInterval = 5
    /// Seconds between later re-reads of a settling capture.
    static let settlingDelay: TimeInterval = 15
    /// Seconds of continuous settling after which re-reading stops until a person or a new epoch asks again.
    static let settlingCap: TimeInterval = 300

    /// Whether the pane is open, as the view last reported it; `nil` until the view reports after appearing.
    var paneOpen: Bool?
    /// The listing generation; every read gets the next one, and only the latest may apply.
    var generation: UInt64 = 0
    /// The member the current epoch reads.
    var memberID: String?
    /// The conversation's member ids when the epoch began, to recognise a changed member set.
    var memberIDs: [String] = []
    /// The shown status of that member when the epoch began, to recognise a transition.
    var shownStatus: TaskStatus?
    /// A read is owed: nothing has been read in this epoch, or the epoch was marked stale.
    var needsRead = true
    /// The last applied result of this member is `pending` with reason `capture_settling`.
    var appliedSettling = false
    /// When the first settling result of this epoch was applied.
    var settlingSince: Date?
    /// How many settling results this epoch has applied.
    var settlingResults = 0
    /// Re-reading stopped at the cap; only "Check again" or a new epoch reads again.
    var capped = false
    /// How many times a read was repeated after a runtime change superseded it.
    var supersededRetries = 0
}
