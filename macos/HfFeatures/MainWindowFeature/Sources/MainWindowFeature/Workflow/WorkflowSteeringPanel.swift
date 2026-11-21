import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSteeringPanel

/// Exact selected-root conversation and request-local approvals share one scrolling body.
struct WorkflowSteeringPanel<VM: WorkflowViewModel>: View {
    var viewModel: VM
    var compactCoexistence = false
    var ownsFallbackApproval = true
    var showsFallbackBubbles = true
    var rootApprovalController: CallerApprovalController?
    var ownsRootApprovalObservation = true
    var taskApprovalController: CallerApprovalController?
    var ownsTaskApprovalObservation = true
    var onFooterHeight: (WorkflowLayoutHeights) -> Void = { _ in }

    var body: some View {
        let state = viewModel.steering
        let authority = viewModel.steeringAuthority
        let footerDelta = compactCoexistence && !viewModel.steeringFailedQueue
            ? WorkflowCompactMetrics.regularWrapper - WorkflowCompactMetrics.compactWrapper : 0
        VStack(alignment: .leading, spacing: compactCoexistence ? WorkflowCompactMetrics.compactInner : WorkflowCompactMetrics.regularInner) {
            ScrollView {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                    if let status = state.statusLine {
                        Text(status)
.font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                            .accessibilityIdentifier("workflow-steering-status")
                    }
                    ForEach(state.messages) { message in
                        Text(message.text)
.font(.hf(.body))
.textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: message.isCaller ? .trailing : .leading)
                            .accessibilityLabel((message.isCaller ? "You: " : "Orchestrator: ") + message.text)
                    }
                    if viewModel.nativeActivity == nil, showsFallbackBubbles, !viewModel.activityMessageBubbles.isEmpty {
                        WorkMessageBubblesView(bubbles: viewModel.activityMessageBubbles, onCancel: viewModel.cancelActivityMessage,
                                               isCancelDisabled: viewModel.isBusy)
                    }
                    if let note = state.note { Text(note).font(.hf(.secondary)) }
                    if let reason = state.reason { Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                    if state.partialHistory {
                        Text("Earlier conversation may be unavailable.").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    }
                    if viewModel.rootOwnsCallerApprovals, let run = viewModel.selectedRun {
                        CallerApprovalPanel(workflowRunID: run.id,
                                            polls: WorkflowRootApprovalScope.shouldPoll(run: run),
                                            pendingDisclosures: true, rootScope: WorkflowRootApprovalScope(run: run),
                                            suppliedController: rootApprovalController, ownsObservation: ownsRootApprovalObservation)
                    }
                    if ownsFallbackApproval, viewModel.runSidebar.approval.mounts,
                       let taskID = viewModel.activityMessageTarget.taskID {
                        CallerApprovalPanel(taskID: taskID, polls: viewModel.runSidebar.approval.polls, pendingDisclosures: true,
                                            suppliedController: taskApprovalController, ownsObservation: ownsTaskApprovalObservation)
                    }
                    if state.canDismiss {
                        Button("Dismiss") { viewModel.dismissSteering(authority: authority) }
                            .disabled(viewModel.steeringRevalidating)
.buttonStyle(MonitorButtonStyle(.glass))
                            .accessibilityIdentifier("workflow-steering-dismiss")
                    }
                    if state.isDismissed, viewModel.selectedRun?.status == "paused",
                       viewModel.selectedRun?.attentionCheckpointID == nil, viewModel.selectedRun?.continuationDecisionID == nil {
                        Text("Resume is unavailable.").font(.hf(.secondary))
                        if let reason = state.resumeReason { Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                    }
                    if let caption = state.caption { Text(caption).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                    if state.opensNeedsYou {
                        Button("Open Needs you") { viewModel.openSteeringNeedsYou(authority: authority) }
                            .disabled(viewModel.steeringRevalidating)
.buttonStyle(MonitorButtonStyle(.glass))
                            .accessibilityIdentifier("workflow-steering-needs-you")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollChrome())
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("workflow-steering-history-viewport")
            WorkflowSteeringFooter(viewModel: viewModel, compactCoexistence: compactCoexistence)
            .onGeometryChange(for: WorkflowLayoutHeights.self) {
                let height = $0.size.height
                return WorkflowLayoutHeights(actual: height, regular: height + footerDelta)
            } action: { onFooterHeight($0) }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, HfRadius.Metrics.spacing12)
        .padding(.vertical, compactCoexistence ? WorkflowCompactMetrics.compactRootPadding : WorkflowCompactMetrics.regularRootPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-steering-panel")
    }

}

#if DEBUG
#Preview("Root steering - light") {
    WorkflowSteeringPanel(viewModel: WorkflowSteeringPreview.make()).preferredColorScheme(.light)
}

#Preview("Root steering - dark") {
    WorkflowSteeringPanel(viewModel: WorkflowSteeringPreview.make()).preferredColorScheme(.dark)
}

#Preview("Root steering - stale") {
    WorkflowSteeringPanel(viewModel: WorkflowSteeringPreview.make(state: "stale")).preferredColorScheme(.light)
}

#Preview("Root steering - dismissing") {
    WorkflowSteeringPanel(viewModel: WorkflowSteeringPreview.make(state: "dismiss_pending_settlement")).preferredColorScheme(.dark)
}
#endif
