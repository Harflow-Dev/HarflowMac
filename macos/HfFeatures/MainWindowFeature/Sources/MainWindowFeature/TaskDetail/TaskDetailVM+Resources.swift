import Foundation
import MonitorCore

// MARK: - TaskDetailVM + Resources

extension TaskDetailVM {
    func prepareResourceContext(task: TaskInfo) {
        let input = task.raw["phase_slots"]
        guard resourceContextTaskID != task.taskID || resourceContextInput != input else { return }
        if resourceContextTaskID != task.taskID {
            resourceContext = nil
            resourceBlockersExpanded = false
        }
        resourceContextTaskID = task.taskID
        resourceContextInput = input
        resourceContextWork?.cancel()
        let token = UUID()
        resourceContextGeneration = token
        let taskID = task.taskID
        let raw = task.raw
        resourceContextWork = Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) { TaskDetailResourceContext.prepare(taskID: taskID, raw: raw) }.value
            guard let self, !Task.isCancelled, resourceContextGeneration == token, currentTaskID == taskID else { return }
            if resourceContext != next { resourceContext = next }
        }
    }

    func resetResourceContext() {
        resourceContextGeneration = UUID()
        resourceContextWork?.cancel()
        resourceContextWork = nil
        resourceContextTaskID = nil
        resourceContextInput = nil
        resourceContext = nil
        resourceBlockersExpanded = false
    }

    func didToggleResourceBlockers() { resourceBlockersExpanded.toggle() }
    func didOpenResourceSlots() { routing.showResourceSlots() }
}
