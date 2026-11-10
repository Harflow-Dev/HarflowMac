import Combine
import Foundation
import MonitorCore

// MARK: - Stopping presentation

extension TaskDetailVM {
    func subscribeToStopping(epoch: UUID) {
        useCase.stoppingChangesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, timelineEpoch == epoch, didSubscribe else { return }
                recompute()
            }
            .store(in: &cancellables)
    }

    func stoppingPresentation(task: TaskInfo) -> Bool {
        let snapshot = useCase.snapshot(currentTaskID)
        return chrome == .standalone && task.status == .running && !task.takenOver
            && snapshot?.taskID == currentTaskID && snapshot?.status == .running
            && snapshot?.supervision?.ownerState == "alive" && snapshot?.takenOver == false
            && useCase.isStopping(currentTaskID)
    }
}
