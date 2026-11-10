import Foundation

// MARK: - TaskStateTreatment

/// Snapshot-supported uncertainty shown only by the standalone task mount.
struct TaskStateTreatment: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case statusUnavailable, ownerLost, unverified, reconstructed, unknownFailed, stopping, settling
    }

    let taskID: String
    let kind: Kind
    var continuation: TaskContinuationPresentation?
    var isStopDisabled = false
    var showsCopyResumeCommand = false

    var isLeadingNotice: Bool {
        continuation?.phase == .accepted || kind == .statusUnavailable || kind == .reconstructed || kind == .stopping || kind == .settling
    }

    var id: String { "activity-task-state-" + taskID }

    static func project(taskID: String, evidence: TaskSnapshotEvidence?, isBusy: Bool,
                        canCancel: Bool, hasResumeCommand: Bool, isStopping: Bool = false,
                        isSettling: Bool = false, isStatusUnavailable: Bool = false) -> Self? {
        if isStatusUnavailable { return Self(taskID: taskID, kind: .statusUnavailable) }
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
        case let status where status.isTerminal && isSettling: kind = .settling
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
        if !isStatusUnavailable, let continuationPresentation {
            return TaskStateTreatment(taskID: task.taskID, kind: .unknownFailed, continuation: continuationPresentation,
                                      showsCopyResumeCommand: resumeCommand != nil)
        }
        return .project(taskID: task.taskID, evidence: snapshotEvidence, isBusy: isBusy,
                        canCancel: canCancel, hasResumeCommand: resumeCommand != nil, isStopping: isStopping,
                        isSettling: isSettling, isStatusUnavailable: isStatusUnavailable)
    }

    func didTapRefreshState() {}
}
