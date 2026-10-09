import MonitorCore
import PbCommon

/// Main-actor dialog construction keeps action delivery independent of rendering equality.
@MainActor
enum ParallelTakeover {
    typealias Context = (any ParallelUseCase, any ParallelRouting, String?)

    static func dialog(taskID: String, task: TaskInfo?, snapshot: TaskInfo?,
                       context: @escaping () -> Context?) -> AlertContent? {
        guard WorkflowNodePresentation.allowsTerminal(snapshot ?? task), let task else { return nil }
        let title = task.status.isRunning ? "Take over this task?" : "Continue this session in a terminal?"
        let button = task.status.isRunning ? "Stop it and take over" : "Continue in terminal"
        let message = "The headless run is stopped first if it is still going, then the same conversation opens in Terminal.app. It runs "
            + "under your own default permissions, not \(task.freedom ?? "this task's freedom")."
        return AlertContent(title: title, description: message) {
            AlertAction(title: button) {
                guard let (useCase, routing, currentID) = context() else { return }
                guard currentID == taskID else {
                    useCase.setOutcome(currentID ?? taskID, "The conversation moved on — review and try again.")
                    return
                }
                useCase.beginTakeover(taskID: taskID)
                routing.selectTask(taskID)
            }
        }
    }
}
