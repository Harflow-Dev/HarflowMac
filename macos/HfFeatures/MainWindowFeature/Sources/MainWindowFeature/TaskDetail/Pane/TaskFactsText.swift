//
//  TaskFactsText.swift
//  MainWindowFeature
//
//  The wording of the Events tab's Task group, kept apart from the view so each value is a plain function of
//  the snapshot it is read from.
//

import Foundation
import HfRepository
import HfUI
import MonitorCore

// MARK: - TaskFactsText

/// Values for the Task facts group. Every qualifier is derived only from a status snapshot whose status equals
/// the status shown; a listing row never supports one.
enum TaskFactsText {

    /// The status label, with "taken over" appended when the engine reports it.
    static func status(_ task: TaskInfo) -> String {
        task.takenOver ? "\(task.status.label) · taken over" : task.status.label
    }

    /// `backend · model`, or the backend alone before the snapshot names a model.
    static func harness(task: TaskInfo, model: InspectorModel?) -> String {
        [task.backend, model?.detail.model ?? task.model].compactMap(\.self).joined(separator: " · ")
    }

    /// The repository's folder name; its full path is the row's help text.
    static func repository(_ task: TaskInfo) -> String {
        task.repoPath.isEmpty ? "—" : Format.repoName(task.repoPath)
    }

    /// "N turns" once the conversation has follow-ups, else "1".
    static func turns(_ turnsText: String?) -> String { turnsText ?? "1" }

    /// The design's Continuity text.
    static let continuityText =
        "Harflow began observing this run again after its dispatcher restarted. Ownership of the run did not change."

    /// The Continuity caption.
    static let continuityCaption = "Time shown is process start evidence, not when the restart happened."

    /// The What was enforced caption.
    static let enforcementCaption = "Reported by the engine for this task. Each item is claimed only as far as it says."
}

// MARK: - TaskSnapshotEvidence

/// What the pane's exit row and first-show default may claim: the status shown and the status snapshot, if any,
/// that supports a qualifier. A listing row (no snapshot, or one for another status) never supports one.
struct TaskSnapshotEvidence: Equatable, Sendable {
    /// The status shown.
    let status: TaskStatus
    let takenOver: Bool
    /// The status of the snapshot the exit and qualifiers come from, `nil` without one.
    let snapshotStatus: TaskStatus?
    let exitCode: Int?
    /// The observed `log.state` from the standalone (activity-enabled) observation.
    let logState: EventLogState?
    /// The matching snapshot's `supervision.owner_state`; `nil` without a matching snapshot.
    var ownerState: String?
    /// The recorded duration of a settled task, from the matching snapshot only and under `TaskSettledDuration`'s
    /// guard (terminal, exit observed, duration recorded); `nil` otherwise.
    var settledDuration: TimeInterval?

    /// Whether a snapshot of the status shown is available.
    var hasMatchingSnapshot: Bool { snapshotStatus == status }

    /// The exit row. A real exit code is shown whenever the matching snapshot has one. "Not observed" only for a
    /// done task with no exit, and for a failed task with no exit whose log state is `incomplete`; every other
    /// terminal status without an exit, and every state without matching evidence, shows a dash.
    var exitText: String {
        guard status.isTerminal, hasMatchingSnapshot else { return "—" }
        if let exitCode { return String(exitCode) }
        switch status {
        case .completed: return "Not observed"
        case .failed: return logState == .incomplete ? "Not observed" : "—"
        default: return "—"
        }
    }

    /// The first-show default. Every state starts closed except a done task whose own snapshot observed an exit,
    /// which opens at split widths. A taken-over task is closed before the done branch; a done task waits for its
    /// snapshot.
    var paneDefault: TaskPaneController.DefaultInput {
        let tab: TaskPaneStateStore.Tab = status.isTerminal ? .changes : .events
        if takenOver { return .init(isReady: true, opensAtSplit: false, tab: tab) }
        guard status == .completed else { return .init(isReady: true, opensAtSplit: false, tab: tab) }
        guard hasMatchingSnapshot else { return .init() }
        return .init(isReady: true, opensAtSplit: exitCode != nil, tab: tab)
    }
}

// MARK: - TaskDetailViewModel

extension TaskDetailViewModel {
    /// The evidence for the pane's exit row and default, from the shown task, its status snapshot and the
    /// observation frame of the shown member. `nil` before the task is known.
    var snapshotEvidence: TaskSnapshotEvidence? {
        guard let task else { return nil }
        let snapshot = inspectorModel.flatMap { $0.hasSnapshot ? $0.detail : nil }
        let matching = snapshot.flatMap { $0.status == task.status ? $0 : nil }
        return TaskSnapshotEvidence(status: task.status, takenOver: task.takenOver, snapshotStatus: snapshot?.status,
                                    exitCode: snapshot?.exitCode, logState: observationFrames[task.taskID]?.logState,
                                    ownerState: matching?.supervision?.ownerState,
                                    settledDuration: matching.flatMap(TaskSettledDuration.seconds(for:)))
    }
}
