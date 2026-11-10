import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - TaskStatusReadAvailability

/// Presentation authority from the latest admitted read, independently of the retained display cache.
enum TaskStatusReadAvailability: Equatable, Sendable {
    case unread, available, unavailable

    init(outcome: TaskSnapshotReadOutcome?, taskID: String) {
        guard let outcome else { self = .unread; return }
        self = outcome.task?.taskID == taskID ? .available : .unavailable
    }
}

extension TaskDetailVM {
    var isStatusUnavailable: Bool { chrome == .standalone && statusReadAvailability == .unavailable }
    var hasStatusAuthority: Bool { chrome != .standalone || statusReadAvailability == .available }

    func latestStatusReadAvailability() -> TaskStatusReadAvailability {
        .init(outcome: useCase.statusReadOutcome(currentTaskID), taskID: currentTaskID)
    }

    /// Actual commands reread metadata synchronously, even before queued presentation invalidations arrive.
    func latestActionTask() -> TaskInfo? {
        guard chrome == .standalone else { return task }
        if let captured = continuationSession.runtime, useCase.continuationRuntime() != captured { return nil }
        guard !continuationLocksActionsFresh else { return nil }
        guard let displayed = task, displayed.taskID == currentTaskID else { return nil }
        guard let fresh = useCase.statusReadOutcome(currentTaskID)?.task, fresh.taskID == currentTaskID else { return nil }
        let listed = useCase.task(currentTaskID) ?? displayed
        return WorkflowNodePresentation.merged(fresh, with: listed)
    }

    func allowsFreshStop() -> Bool {
        guard let fresh = latestActionTask() else { return false }
        return !isWorkflowBuilder && !isBusy && fresh.status.isRunning && !fresh.takenOver
            && fresh.raw["execution_kind"]?.stringValue != "native_subagent"
            && !WorkflowNodePresentation.isNativeControl(fresh)
    }

    func subscribeToStatusReads(epoch: UUID) {
        guard chrome == .standalone else { return }
        useCase.statusReadChangesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                let revision = useCase.statusReadOutcome(currentTaskID)?.revision
                let retryContinuation = continuationPresentation?.locksActions == true && revision != continuationSession.statusRevision
                continuationSession.statusRevision = revision
                guard latestStatusReadAvailability() != statusReadAvailability || retryContinuation else { return }
                if retryContinuation { continuationReadPulse() }
                recompute()
            }
            .store(in: &cancellables)
    }
}
