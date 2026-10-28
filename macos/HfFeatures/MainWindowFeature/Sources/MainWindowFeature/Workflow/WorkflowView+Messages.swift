import HfUI
import SwiftUI

// MARK: - WorkflowView messages

extension WorkflowView {
    var runReadError: some View {
        ContentUnavailableView("Workflow could not be loaded", systemImage: "exclamationmark.triangle")
    }

    var workMessageBox: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            WorkMessageQueue(items: WorkMessageQueue.items(raw: viewModel.selectedRun?.raw ?? [:]),
                             isBusy: viewModel.isBusy, onCancel: viewModel.cancelWorkMessage)
            MessageBoxView(model: MessageBoxModel(
                canSend: true, canContinue: false, isBusy: viewModel.isBusy,
                label: viewModel.selectedRun?.isBuilder == false ? "Message this workflow" : "Message the workflow builder",
                hint: viewModel.selectedRun == nil ? "Start a workflow builder conversation" : "Send queues; Send now requests immediate delivery when safe",
                placeholder: "Queue a message…", buttonLabel: "Send"
            ), onSubmitNow: { viewModel.submitWorkMessage($0, now: true) }) {
                viewModel.submitWorkMessage($0, now: false)
            }
        }
        .accessibilityIdentifier("workflow-builder-message-composer")
    }

}
