//
//  ParallelLaneStatus.swift
//  MainWindowFeature
//
//  What a Parallel lane's head says about its current member: the caption under the title (harness, model and
//  taken over) and the status badge model behind the head's "Running 03:24". Both are pure functions of values the
//  VM already holds. Design reference: HarflowDesign 4ff7d83, `states-parallel-lanes.js` `caption` and `lane`.
//

import Foundation
import HfRepository
import HfUI
import MonitorCore

// MARK: - ParallelLaneStatus

enum ParallelLaneStatus {
    /// "Claude · Opus 5.5", "Codex" when the model is unknown or blank, plus " · taken over" when the current member
    /// was taken over in a terminal. The model is shown as the listing carries it.
    nonisolated static func caption(current: TaskInfo) -> String {
        var parts = [BackendStyle.displayName(current.backend)]
        if let model = current.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty { parts.append(model) }
        if current.takenOver { parts.append("taken over") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The harness name used by the lane's composer labels: "Claude", "Codex".
    nonisolated static func harnessName(current: TaskInfo) -> String { BackendStyle.displayName(current.backend) }

    /// The lane's status. A qualifier ("exit not observed", "owner lost") only ever comes from a snapshot of the
    /// status shown, never from a listing row; the recorded duration comes from `TaskSettledDuration` on the merged
    /// current member. The clock is carried by the model and passed outside `TaskSnapshotEvidence`.
    nonisolated static func make(current: TaskInfo, snapshot: TaskInfo?, frame: EventObservationFrame?) -> TaskBadgeModel {
        let matching = snapshot.flatMap { $0.status == current.status ? $0 : nil }
        let evidence = TaskSnapshotEvidence(
            status: current.status, takenOver: current.takenOver, snapshotStatus: snapshot?.status,
            exitCode: snapshot?.exitCode, logState: frame?.logState, ownerState: matching?.supervision?.ownerState,
            settledDuration: TaskSettledDuration.seconds(for: current))
        return TaskBadgeModel.make(evidence: evidence, startedAt: current.startedAt)
    }

    /// The end row of a settled lane: the status label, " · taken over" when taken over, then " · " and the recorded
    /// clock when there is one ("Done · 04:51", "Cancelled · taken over · 04:31"). `nil` while the current member runs
    /// or has no terminal status. Tone and glyph come from the lane status.
    nonisolated static func settledLine(current: TaskInfo, status: TaskBadgeModel) -> ActivityFeedTailPresentation.SettledLine? {
        guard current.status.isTerminal else { return nil }
        var text = status.label
        if let suffix = status.suffix { text += " " + suffix }
        if case let .fixed(seconds) = status.clock { text += " · " + Format.clock(seconds) }
        let tone: ActivityFeedTailPresentation.SettledLine.Tone = switch status.tone {
        case .done: .success
        case .failed: .danger
        default: .secondary
        }
        let symbol: String? = switch status.tone {
        case .done: "checkmark"
        case .neutral: "stop.fill"
        default: if case let .symbol(name) = status.icon { name } else { nil }
        }
        return .init(text: text, tone: tone, symbol: symbol)
    }
}
