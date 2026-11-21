//
//  ParallelColumnModel.swift
//  MainWindowFeature
//
//  Presentation and action closures come from the VM. Lightweight reading and disclosure state
//  survives viewport eviction; measured row geometry stays local to this mounted activity view.
//
//  Monitor piece 13: a column is one agent CONVERSATION (a resume chain), not one task — `rows` is
//  the whole conversation's concatenated timeline (`MonitorCore.ConversationTimeline`, the same
//  shape TaskDetail's own `TimelinePaneView` renders), with a turn separator ahead of every
//  follow-up and each row's own `live` flag already scoped to its own turn.
//
//  Redesign follow-up: the header and feed mirror the single-task screen — `activityRows` is `rows`
//  folded into tool cards by the VM (`ActivityRowsBuilder`), rendered exactly like `TimelinePaneView`.
//

import AppKit
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnModel

/// Presentation data for one Parallel column: the conversation's fresh CURRENT member (status,
/// take-over and buttons all act on it), everything today's outcome line/busy state/event stream say
/// about it, and the two actions its buttons perform.
struct ParallelColumnModel: Identifiable {
    let id: String
    let task: TaskInfo
    let title: String
    /// "<Backend> · <repo name>", plus "· N turns" once the conversation has more than one turn.
    let subtitle: String
    let isBusy: Bool
    let outcomeMessage: String?
    let showPrompt: Bool
    /// The conversation's stored first request while View prompt is on; `nil` otherwise. Not rendered state of its own: the VM reads it.
    var request: TaskRequestReadState?
    var onReadRequest: ((Int) -> Void)?
    var onCopyRequest: ((String) -> Void)?
    /// "Copied", or the fallback hint after a failed copy.
    var requestFeedback: String?
    /// Raw timeline items and separators for the complete step count.
    let rows: [ConversationTimelineRow]
    /// What the feed renders: `rows` with adjacent tool calls folded into cards.
    var activitySnapshot: ActivityFeedSnapshot?
    let activityRows: [ActivityRow]
    /// The "what is it doing now" line under the feed; `nil` unless a call is pending in a running turn.
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var workMessages: [WorkMessageBubble] = []
    /// True while NO member of this conversation has any timeline item yet AND at least one
    /// member's own event stream is still `.loading` (Monitor piece 12, Design point 4, extended
    /// across every member for piece 13) — the column shows `SkeletonRows` instead of the empty
    /// timeline while this holds.
    var isLoading: Bool
    var emptyText: String?
    /// From the current member's snapshot only — no fallback to `task.summary` (F4-40, a deliberate
    /// difference from `ChangesPane`). A settled lane shows it first, as its result callout.
    let summary: String?
    /// The lane feed's activity-item count; `nil` while no item row is loaded —
    /// a zero, still-loading or unavailable feed omits the count rather than claiming "0 activity items".
    var stepCountText: String?
    /// "No tool calls recorded", proven only for a terminal current task from the UNFILTERED
    /// member inputs — never inferred from the visible page having none.
    var noToolCallsText: String?
    /// Take over in a terminal; only the Graph inspector offers it (a lane's actions menu holds Open task only).
    var onTapTakeover: (() -> Void)?
    let onTapOpenTask: () -> Void
    /// Opens another task by id (a consumed follow-up's successor).
    var onSelectTask: ((String) -> Void)?
    /// When the conversation's FIRST turn started — every row's elapsed time counts from here, as
    /// TaskDetail's Timeline does; the current turn's own start would clamp earlier turns to 0.
    var start: Date?
    var animatesArrival = false
    var onDidPresent: () -> Void = {}
    var memberTaskIDs: Set<String> = []
    var isResident = true
    var isVisible = true
    var history = EventHistoryState()
    var paginationRevision = 0
    var onLoadMore: (() -> Bool)?
    var cachedHistoryNotice: String?
    var onAdoptWindow: (() -> Void)?
    var onSubmitMessage: ((String, Bool) -> Bool)?
    var onCancelMessage: ((String) -> Void)?
    /// The surface that draws this column; the VM sets `.inspector` for the Graph inspector's VM.
    var chrome = ParallelColumnChrome.lane
    /// Set only by a workflow VM; `nil` for Group lanes. Takeover keeps its own copy and wins on its own lane.
    var messageLock: ParallelMessageLock?
    var messageAdmission: WorkflowMessageAdmission?
    /// Set only for the Graph inspector when the run takes caller approvals: the node task's approval panel is drawn
    /// between the feed and the composer.
    var inspectorApproval: WorkflowSelectedApprovalGate?
    /// The inspector keeps the task's own title and status row only where the pane head does not carry it (the orchestrator).
    var showsInspectorTitle = false
    /// The lane caption under the title: "Claude · Opus 5.5", plus " · taken over". Empty means derive from `task`.
    var caption = ""
    /// The harness name for the composer labels. Empty means derive from `task`.
    var harnessName = ""
    /// The lane head's status. `nil` means derive from `task` alone.
    var status: TaskBadgeModel?

    var laneCaption: String { caption.isEmpty ? ParallelLaneStatus.caption(current: task) : caption }
    var laneHarnessName: String { harnessName.isEmpty ? ParallelLaneStatus.harnessName(current: task) : harnessName }
    var laneStatus: TaskBadgeModel { status ?? ParallelLaneStatus.make(current: task, snapshot: nil, frame: nil) }

    /// The selected root renders its steering composer outside this inspector.
    var hidesInspectorComposer = false

    /// Why a lane composer is locked: takeover first, since it is the more specific reason on its own lane.
    var laneComposerLock: MessageBoxDisabledReason? {
        if task.takenOver { return .takenOver }
        return messageLock?.disabledReason
    }

    /// The node pane composer locks bare on an unsupported runtime unless takeover already explains the lock.
    var inspectorMessagingUnsupported: Bool { !task.takenOver && messageLock == .messagingUnsupported }

    /// The lane's composer: Queue only (no Send now), labelled for the harness.
    var laneMessageBoxModel: MessageBoxModel {
        let harness = laneHarnessName
        let lock = laneComposerLock
        let unsupported = !task.takenOver && messageLock == .messagingUnsupported
        return MessageBoxModel(
            canSend: lock == nil && !unsupported && onSubmitMessage != nil, canContinue: false, isBusy: isBusy,
            label: "Message \(harness)", hint: "", placeholder: lock?.text ?? (unsupported ? "" : "Message \(harness)"),
            buttonLabel: "Send", isLocked: lock != nil || unsupported,
            fieldAccessibilityLabel: "Message \(harness)", sendAccessibilityLabel: "Send to \(harness)")
    }

    /// The node pane's composer. Unsupported messaging locks it with no placeholder or hint and no Send now,
    /// like the task screen's.
    var inspectorMessageBoxModel: MessageBoxModel {
        let unsupported = inspectorMessagingUnsupported
        let phase = task.takenOver ? nil : messageLock?.disabledReason
        let reason = task.takenOver ? MessageBoxDisabledReason.takenOver : phase
        return MessageBoxModel(
            canSend: reason == nil && !unsupported && onSubmitMessage != nil, canContinue: false, isBusy: isBusy,
            label: "Message this task", hint: unsupported || phase != nil ? "" : "Send queues; Send now requests immediate delivery when safe",
            placeholder: reason?.text ?? (unsupported ? "" : "Queue a message…"),
            buttonLabel: "Send", isLocked: reason != nil || unsupported,
            showsSendNow: !unsupported && phase == nil)
    }

    /// "<Backend> · <repo name>" plus "· N turns" when `turns > 1` — the lane header's subtitle,
    /// without the session id.
    static func subtitle(repoPath: String, backend: String, turns: Int) -> String {
        var parts = [BackendStyle.displayName(backend), Format.repoName(repoPath)].filter { !$0.isEmpty }
        if turns > 1 { parts.append("\(turns) turns") }
        return parts.joined(separator: " · ")
    }

    /// The same column drawn by another surface. The Graph inspector forces `.inspector`, which draws the
    /// pane's page background and the system divider.
    func withChrome(_ chrome: ParallelColumnChrome, showsInspectorTitle: Bool = false) -> ParallelColumnModel {
        var copy = self
        copy.chrome = chrome
        copy.showsInspectorTitle = showsInspectorTitle
        return copy
    }

    /// Raw item count excludes conversation separators.
    static func itemCount(_ rows: [ConversationTimelineRow]) -> Int {
        rows.filter { if case .item = $0.kind { return true }; return false }.count
    }
}
