import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - Workflow activity selection

extension WorkflowView {
    @ViewBuilder
    var answerHistoryHeader: some View {
            if let outcome = viewModel.interactionOutcome {
                WorkflowInteractionOutcomeView(receipt: outcome, savedDraft: viewModel.interactionSavedDraft, isRaceOutcome: true)
            }
            if let run = viewModel.selectedRun, !run.interactionHistory.isEmpty {
                DisclosureGroup("Answer history") {
                    if run.raw["interaction_history_truncated"]?.boolValue == true {
                        Text("Earlier answers or long answer text may be omitted.")
                            .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                    }
                    ForEach(run.interactionHistory, id: \.interactionID) { receipt in
                        WorkflowInteractionOutcomeView(receipt: receipt)
                    }
                }
                .padding(.horizontal, HfRadius.Metrics.spacing12)
                .padding(.vertical, HfRadius.Metrics.spacing6)
            }
    }

    var selectedTaskID: String? {
        guard let nodeID = viewModel.selectedNodeID else {
            return nil
        }
        return viewModel.selectedRun?
            .activations
            .last { $0["node_id"]?.stringValue == nodeID && $0["role"]?.stringValue == "node" }?["tasks"]?
            .arrayValue?
            .last?["task_id"]?
            .stringValue
    }

    /// The shared recovery-overlay eligibility of the current selected run: the loaded
    /// non-builder surface plus the unchanged `WorkflowRecoveryPresentation.showsRecovery`.
    var recoveryEligibleRunID: String? {
        WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: viewModel.selectedRun,
            initialLoadingKind: viewModel.initialLoadingKind,
            initialLoadFailed: viewModel.initialLoadFailed, answeredInteractionID: viewModel.interactionOutcome?.interactionID)
    }
}

// MARK: - WorkflowViewModel defaults

extension WorkflowViewModel {
    var validationDependencies: [String: JSONValue] { [:] }
    var branchSelection: WorkflowBranchSelection { WorkflowBranchSelection() }
}
