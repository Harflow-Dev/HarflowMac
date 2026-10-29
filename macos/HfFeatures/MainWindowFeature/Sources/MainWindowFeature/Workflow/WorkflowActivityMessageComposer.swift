import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowActivityMessageTarget

/// An Activity composer never silently redirects a node message to its parent run.
struct WorkflowActivityMessageTarget: Equatable, Hashable {
    let runID: String?
    let taskID: String?
    let unavailableReason: String?

    static func resolve(run: WorkflowRunModel?, sidebar: WorkflowRunSidebarPresentation) -> Self {
        guard let run else { return .init(runID: nil, taskID: nil, unavailableReason: "The workflow is not loaded.") }
        guard let activationID = sidebar.activationID,
              let activation = run.activations.first(where: { $0["id"]?.stringValue == activationID }) else {
            return .init(runID: nil, taskID: nil, unavailableReason: "This node has no issued task or child workflow to message yet.")
        }
        if let child = sidebar.childRunID, !child.isEmpty {
            let currentChild = activation["invocation"]?["child_workflow_run_id"]?.stringValue
                ?? activation["child_workflow_run_id"]?.stringValue ?? activation["workflow_run_id"]?.stringValue
            guard currentChild == child else {
                return .init(runID: nil, taskID: nil, unavailableReason: "The selected Activity target is refreshing.")
            }
            return .init(runID: child, taskID: nil, unavailableReason: nil)
        }
        if let task = sidebar.taskIDs.last, !task.isEmpty {
            guard WorkflowJSON.objects(activation["tasks"]).contains(where: { $0["task_id"]?.stringValue == task }) else {
                return .init(runID: nil, taskID: nil, unavailableReason: "The selected Activity target is refreshing.")
            }
            return .init(runID: run.id, taskID: task, unavailableReason: nil)
        }
        return .init(runID: nil, taskID: nil,
                     unavailableReason: "This node has no issued task or child workflow to message yet.")
    }

    func includes(_ message: JSONValue) -> Bool {
        guard let taskID else { return message["target"]?["kind"]?.stringValue == "workflow" }
        return message["target"]?["task_id"]?.stringValue == taskID || message["delivery_task_id"]?.stringValue == taskID
    }
}

// MARK: - WorkflowActivityMessageComposer

/// Fallback Activity footer for native, child and unavailable execution surfaces.
/// Headless conversations use the same footer inside their Parallel column.
struct WorkflowActivityMessageComposer<VM: WorkflowViewModel>: View {
    var viewModel: VM
    /// Native Activity draws its bubbles in the transcript. This footer keeps them when it is the
    /// only transcript on the surface.
    var showsBubbles = true

    var body: some View {
        let target = viewModel.activityMessageTarget
        VStack(spacing: HfRadius.Metrics.zero) {
            if showsBubbles {
                WorkMessageBubblesView(bubbles: viewModel.activityMessageBubbles, onCancel: viewModel.cancelActivityMessage,
                                         isCancelDisabled: viewModel.isBusy)
            }
            if let reason = viewModel.activityMessageReadError {
                Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
            MessageBoxView(model: MessageBoxModel(
                canSend: target.unavailableReason == nil, canContinue: false, isBusy: viewModel.isBusy,
                label: target.taskID == nil ? "Message the child workflow orchestrator" : "Message this node",
                hint: "Send queues; Send now requests immediate delivery when safe",
                placeholder: target.unavailableReason ?? "Queue a message…", buttonLabel: "Send",
                isLocked: target.unavailableReason != nil
            ), onSubmitNow: { viewModel.submitActivityMessage($0, now: true) }, isCompact: true) {
                viewModel.submitActivityMessage($0, now: false)
            }
            .id(target)
        }
        .accessibilityIdentifier("workflow-activity-message-composer")
        .task(id: target) { await viewModel.refreshActivityMessageState() }
    }
}

#if DEBUG
#Preview("Selected node Activity composer") {
    WorkflowActivityMessageComposer(viewModel: WorkflowPreview.make(run: true))
        .frame(width: 420)
}
#endif
