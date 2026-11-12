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
}
