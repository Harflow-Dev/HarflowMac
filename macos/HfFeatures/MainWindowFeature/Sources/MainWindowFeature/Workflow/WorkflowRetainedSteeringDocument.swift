import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSteeringDocumentInput

/// Includes the authority captured by each action so unchanged text cannot preserve an obsolete command.
struct WorkflowSteeringDocumentInput: Equatable {
    let presentation: WorkflowSteeringPresentation
    let authority: WorkflowSteeringAuthority?
    let revalidating: Bool
    let resumeUnavailable: Bool
}

// MARK: - WorkflowRetainedSteeringDocument

/// Root companion rows are display-only projections; their sessions belong to the selected pane.
@MainActor
enum WorkflowRetainedSteeringDocument {
    static func rows(viewModel: some WorkflowViewModel, controller: CallerApprovalController?) -> [ActivityFeedDocumentEntry] {
        guard let run = viewModel.selectedRun else { return [] }
        let state = viewModel.steering
        let authority = viewModel.steeringAuthority
        let input = WorkflowSteeringDocumentInput(presentation: state, authority: authority,
            revalidating: viewModel.steeringRevalidating,
            resumeUnavailable: state.isDismissed && run.status == "paused"
                && run.attentionCheckpointID == nil && run.continuationDecisionID == nil)
        var rows = historyRows(runID: run.id, state: state, input: input) + approvalRows(run: run, controller: controller)
        if state.canDismiss || state.opensNeedsYou || input.resumeUnavailable || state.caption?.isEmpty == false {
            rows.append(.supplementary(.init(scope: run.id, kind: .steeringControls, input: .steering(input),
                content: AnyView(controls(viewModel: viewModel, input: input)))))
        }
        return rows
    }

    private static func historyRows(runID: String, state: WorkflowSteeringPresentation,
                                    input: WorkflowSteeringDocumentInput) -> [ActivityFeedDocumentEntry] {
        var rows: [ActivityFeedDocumentEntry] = []
        rows.append(.supplementary(.init(scope: runID, kind: .steeringHistory, input: .steering(input), content: AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("Orchestrator").font(.hf(.caption, weight: .semibold)).foregroundStyle(Color.secondaryText)
                if let status = state.statusLine {
                    Text(status)
.font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                        .accessibilityIdentifier("workflow-steering-status")
                }
            }.accessibilityIdentifier("workflow-steering-history-heading")), key: "heading")))
        for message in state.messages {
            rows.append(.supplementary(.init(scope: runID, kind: .steeringMessage, input: .steeringMessage(message), content: AnyView(
                Text(message.text)
.font(.hf(.body))
.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: message.isCaller ? .trailing : .leading)
                    .accessibilityLabel((message.isCaller ? "You: " : "Orchestrator: ") + message.text)), key: String(message.id))))
        }
        if state.note != nil || state.reason != nil || state.partialHistory {
            rows.append(.supplementary(.init(scope: runID, kind: .steeringHistory, input: .steering(input), content: AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    if let note = state.note { Text(note).font(.hf(.secondary)) }
                    if let reason = state.reason { Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                    if state.partialHistory {
                        Text("Earlier conversation may be unavailable.").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    }
                }), key: "outcome")))
        }
        return rows
    }

    private static func approvalRows(run: WorkflowRunModel, controller: CallerApprovalController?) -> [ActivityFeedDocumentEntry] {
        var rows: [ActivityFeedDocumentEntry] = []
        if let controller {
            let scope = WorkflowRootApprovalScope(run: run)
            let cards = controller.cards.filter { scope.contains($0.request) }.map { original in
                var card = original
                card.canRespond = card.canRespond && !controller.isLoading && !controller.isSubmitting && !controller.isResponseQueued
                return ActivityFeedApprovalEntry(source: .workflowRun(run.id), card: card, issuer: scope.issuer(for: card.request))
            }
            if !cards.isEmpty {
                rows.append(.supplementary(.init(scope: "run-" + run.id, kind: .caption,
                    input: .caption("Worker approval requests"), content: AnyView(
                        Text("Worker approval requests")
.font(.hf(.caption, weight: .semibold))
.foregroundStyle(Color.secondaryText)
                            .accessibilityIdentifier("workflow-root-approvals")))))
            }
            rows.append(contentsOf: cards.map(ActivityFeedDocumentEntry.approval))
            if !cards.isEmpty || controller.isLoading || controller.error != nil || controller.nextCursor != nil || controller.acquisitionLimited {
                let status = ActivityFeedSupplementaryRow.ApprovalStatus(loading: controller.isLoading,
                    submitting: controller.isSubmitting || controller.isResponseQueued, hasMore: controller.nextCursor != nil,
                    limited: controller.acquisitionLimited, error: controller.error)
                rows.append(.supplementary(.init(scope: "run-" + run.id, kind: .approvalStatus, input: .approval(status),
                    content: AnyView(WorkflowInspectorApprovalStatus(controller: controller)))))
            }
        }
        return rows
    }

    private static func controls(viewModel: some WorkflowViewModel, input: WorkflowSteeringDocumentInput) -> some View {
        let state = input.presentation
        let authority = input.authority
        return VStack(alignment: .leading, spacing: 12) {
                if state.canDismiss {
                    Button("Dismiss") { viewModel.dismissSteering(authority: authority) }
                        .disabled(input.revalidating)
.buttonStyle(MonitorButtonStyle(.glass))
                        .accessibilityIdentifier("workflow-steering-dismiss")
                }
                if input.resumeUnavailable {
                    Text("Resume is unavailable.").font(.hf(.secondary))
                    if let reason = state.resumeReason { Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                }
                if let caption = state.caption { Text(caption).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                if state.opensNeedsYou {
                    Button("Open Needs you") { viewModel.openSteeringNeedsYou(authority: authority) }
                        .disabled(input.revalidating)
.buttonStyle(MonitorButtonStyle(.glass))
                        .accessibilityIdentifier("workflow-steering-needs-you")
                }
        }
    }
}
