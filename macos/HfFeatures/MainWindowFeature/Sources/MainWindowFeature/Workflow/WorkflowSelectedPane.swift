import Foundation
import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSelectedHeader

/// The selected-node pane's head, computed off the main actor with the rest of the sidebar presentation.
struct WorkflowSelectedHeader: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case worker
        case onDemand
        case orchestrator
    }

    var kind = Kind.worker
    /// The raw status of the attempt the pane shows; `nil` when the node has no attempt yet.
    var attemptStatus: String?
    /// True while the pane shows the node's latest attempt, whose badge follows the canvas node.
    var isLatestAttempt = true
    /// The faint caption beside the title: "On demand" for an on-demand node, nothing otherwise.
    var caption: String?

    /// The badge status. The latest attempt uses the canvas node's own status, so both agree; an older attempt chosen in
    /// the picker keeps its own recorded status. The shared run-status mapping is never changed.
    func badgeStatus(canvasStatus: String) -> String {
        isLatestAttempt ? canvasStatus : (attemptStatus ?? canvasStatus)
    }

    /// The badge label, from the same mapping the canvas node meta uses.
    func badgeLabel(canvasStatus: String) -> String {
        WorkflowNodeStatusPresentation.presentation(status: badgeStatus(canvasStatus: canvasStatus)).label
    }
}

// MARK: - WorkflowSelectedCaption

/// The faint "backend · model · repository" line above a transcript.
enum WorkflowSelectedCaption {
    /// Missing parts are omitted; an optional prefix such as "Call 2" leads the line. `nil` when nothing remains.
    static func make(prefix: String? = nil, backend: String?, model: String?, repository: String?) -> String? {
        var parts: [String] = []
        if let prefix, !prefix.isEmpty { parts.append(prefix) }
        if let backend, !backend.isEmpty { parts.append(BackendStyle.displayName(backend)) }
        if let model, !model.isEmpty { parts.append(model) }
        if let repository, !repository.isEmpty { parts.append(repository) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The backend and model an activation ran with. The activation's own task candidate wins; the node's agent
    /// fills what the activation does not report.
    static func agent(activation: [String: JSONValue]?, node: [String: JSONValue]?) -> (backend: String?, model: String?) {
        let candidates = WorkflowJSON.objects(activation?["tasks"]).compactMap { $0["candidate"]?.objectValue }
            + [activation?["candidate"]?.objectValue].compactMap(\.self)
        let reported = candidates.last { !($0["backend"]?.stringValue ?? "").isEmpty }
        let agent = node?["agent"]?.objectValue
        let backend = reported?["backend"]?.stringValue ?? agent?["backend"]?.stringValue
        let model = candidates.reversed().compactMap { $0["model"]?.stringValue }.first { !$0.isEmpty }
            ?? agent?["model"]?.stringValue
        return (backend, model)
    }
}

// MARK: - WorkflowOnDemandCallRow

/// One selectable call of an on-demand node. The id is the activation id that selects it, including the synthetic
/// `unavailable:<callID>` activation of a call whose execution is missing.
struct WorkflowOnDemandCallRow: Equatable, Identifiable, Sendable {
    let id: String
    let number: Int
    /// The call's raw status ("succeeded", "running", ...).
    let status: String
    let startedAt: Double?
    let finishedAt: Double?
    let taskID: String?

    var isRunning: Bool { status == "running" }

    /// The row text without time: "Call 2 · Done".
    var statusText: String { "Call \(number) · \(Self.statusLabel(status))" }

    /// "Call 2 · Done · 01:12", or without the duration while none is known.
    func summary(now: Date) -> String {
        guard let duration = Self.duration(startedAt: startedAt, finishedAt: finishedAt, isRunning: isRunning, now: now) else { return statusText }
        return statusText + " · " + duration
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "succeeded": "Done"
        case "running": "Running"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Elapsed time as `mm:ss` (`h:mm:ss` from one hour). A settled call uses its own timestamps; a running one counts to
    /// the explicit `now`; anything else has no duration.
    static func duration(startedAt: Double?, finishedAt: Double?, isRunning: Bool, now: Date) -> String? {
        guard let startedAt else { return nil }
        guard let end = finishedAt ?? (isRunning ? now.timeIntervalSince1970 : nil) else { return nil }
        let seconds = Int(max(0, end - startedAt))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// The glyph shown beside the row, from the shared status mapping.
    var indicatorStatus: TaskStatus {
        switch status {
        case "succeeded": .completed
        case "running": .running
        case "failed": .failed
        case "cancelled": .cancelled
        default: .other(status)
        }
    }

    /// Rows newest first, from the standalone projection's attempts and call mapping.
    static func rows(
        activationIDs: [String], numbers: [String: Int], calls: [String: [String: JSONValue]]
    ) -> [WorkflowOnDemandCallRow] {
        activationIDs.enumerated()
.map { index, id in
            let call = calls[id]
            return WorkflowOnDemandCallRow(
                id: id, number: numbers[id] ?? index + 1, status: call?["status"]?.stringValue ?? "unknown",
                startedAt: call?["started_at"]?.doubleValue, finishedAt: call?["finished_at"]?.doubleValue,
                taskID: call?["task_id"]?.stringValue)
        }
.reversed()
    }
}

// MARK: - WorkflowCallDetails

/// What a call carried, kept visible when it has no transcript to show it in.
struct WorkflowCallDetails: Equatable, Sendable {
    let origin: String
    let assignment: String
    let reason: String
    let result: String

    init(call: WorkflowOnDemandCall) {
        self.origin = call.origin
        self.assignment = call.assignment
        self.reason = call.reason
        self.result = call.result
    }
}

// MARK: - WorkflowSelectedApprovalGate

/// Whether the selected-node pane mounts the approval panel, and whether it polls. The same condition as the run sidebar.
struct WorkflowSelectedApprovalGate: Equatable, Sendable {
    var mounts = false
    var polls = false

    static let pollingStatuses: Set<String> = ["running", "needs_attention", "needs_input"]

    static func make(run: [String: JSONValue]) -> Self {
        let mounts = CallerApprovalPanel.containsOptIn(.object(run)) || (run["approval_summary"]?["pending_count"]?.intValue ?? 0) > 0
        return Self(mounts: mounts, polls: mounts && pollingStatuses.contains(run["status"]?.stringValue ?? ""))
    }
}

// MARK: - WorkflowCallDetails placement

extension WorkflowCallDetails {
    /// Whether the details block shows: an on-demand call with details whose transcript is not on screen, either because
    /// the call has no activity at all or because its activity could not resolve the shown conversation.
    static func isShown(isOnDemand: Bool, hasDetails: Bool, hasActivity: Bool, activityShowsConversation: Bool) -> Bool {
        isOnDemand && hasDetails && !(hasActivity && activityShowsConversation)
    }
}

// MARK: - WorkflowSelectedPaneSizing

/// Region limits for the selected-node pane. The transcript is a self-scrolling native feed, so the regions around it are
/// capped and scroll inside, leaving its feed a floor. Both limits take the measured chrome that is not feed: the pane's
/// head, picker and fallback composer, and the inspector column's own header, outcome, boundary, callout, padding and composer.
enum WorkflowSelectedPaneSizing {
    /// The feed always keeps at least this much height.
    static let transcriptFloor: CGFloat = 80
    /// The region above the transcript scrolls beyond this share of the pane.
    static let topRegionShare: CGFloat = 0.5
    /// The approval region scrolls beyond this share of the inspector column.
    static let approvalShare: CGFloat = 0.45
    /// An on-demand call list shows this many rows before it scrolls.
    static let visibleCallRows = 5
    static let callRowHeight: CGFloat = 32

    /// The height the top region (goal, caption or call list) takes: its natural height, limited to half the pane and to
    /// what leaves the feed its floor after all measured chrome (`reserved`: pane head, picker, composer and the column's
    /// own chrome).
    static func topRegionHeight(natural: CGFloat, paneHeight: CGFloat, reserved: CGFloat = 0) -> CGFloat {
        let limit = min(paneHeight * topRegionShare, paneHeight - reserved - transcriptFloor)
        return max(0, min(natural, limit))
    }

    /// The height of the approval region inside the inspector column: its natural height, limited to 45% of the column and to
    /// what leaves the feed its floor after the column's other chrome (`chrome`, which excludes the feed and this region).
    static func approvalHeight(natural: CGFloat, columnHeight: CGFloat, chrome: CGFloat = 0) -> CGFloat {
        let limit = min(columnHeight * approvalShare, columnHeight - chrome - transcriptFloor)
        return max(0, min(natural, limit))
    }

    /// The inspector column's own padding and stack spacing, from its layout.
    static let columnPadding: CGFloat = 16
    static let columnSpacing: CGFloat = 10

    /// The inspector column's chrome: its padding, the stack spacing between `itemCount` children (feed and approval region
    /// included) and the directly measured heights of every child that is neither the feed nor the approval region.
    static func columnChrome(pieces: [CGFloat], itemCount: Int) -> CGFloat {
        columnPadding * 2 + columnSpacing * CGFloat(max(0, itemCount - 1)) + pieces.reduce(0) { $0 + max(0, $1) }
    }

    /// The call list's height: every row up to the visible cap.
    static func callListHeight(rowCount: Int) -> CGFloat {
        CGFloat(min(rowCount, visibleCallRows)) * callRowHeight
    }
}

// MARK: - WorkflowSelectedColumnChromeKey

/// The measured non-feed chrome of the inspector column and its conversation picker (their values add), reported to the pane so the region above the transcript leaves the feed its floor.
struct WorkflowSelectedColumnChromeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
