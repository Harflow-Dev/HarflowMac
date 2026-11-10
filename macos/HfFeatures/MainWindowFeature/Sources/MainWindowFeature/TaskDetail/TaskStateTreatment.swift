import Foundation

// MARK: - TaskStateTreatment

/// Snapshot-supported uncertainty shown only by the standalone task mount.
struct TaskStateTreatment: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case ownerLost, unverified, reconstructed, unknownFailed, stopping
    }

    let taskID: String
    let kind: Kind
    var isStopDisabled = false
    var showsCopyResumeCommand = false

    var isLeadingNotice: Bool { kind == .reconstructed || kind == .stopping }
    var id: String { "activity-task-state-" + taskID }

    static func project(taskID: String, evidence: TaskSnapshotEvidence?, isBusy: Bool,
                        canCancel: Bool, hasResumeCommand: Bool, isStopping: Bool = false) -> Self? {
        guard let evidence, evidence.hasMatchingSnapshot, !evidence.takenOver else { return nil }
        let kind: Kind
        switch evidence.status {
        case .running where isStopping && evidence.ownerState == "alive": kind = .stopping
        case .running:
            switch evidence.ownerState {
            case "dead": kind = .ownerLost
            case "undecidable": kind = .unverified
            default: return nil
            }
        case .completed where evidence.exitCode == nil: kind = .reconstructed
        case .failed where evidence.exitCode == nil && evidence.logState == .incomplete: kind = .unknownFailed
        default: return nil
        }
        return Self(taskID: taskID, kind: kind, isStopDisabled: isBusy || !canCancel,
                    showsCopyResumeCommand: hasResumeCommand)
    }
}

extension TaskDetailViewModel {
    /// Projection belongs to the presentation boundary; repository and use-case values stay domain-only.
    var stateTreatment: TaskStateTreatment? {
        guard let task else { return nil }
        return .project(taskID: task.taskID, evidence: snapshotEvidence, isBusy: isBusy,
                        canCancel: canCancel, hasResumeCommand: resumeCommand != nil, isStopping: isStopping)
    }

    func didTapRefreshState() {}
}
