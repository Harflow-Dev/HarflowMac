import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - Workflow activity selection

extension WorkflowView {
    @ViewBuilder
    var answerHistoryHeader: some View {
            if let outcome = viewModel.interactionOutcome, !headerOutcomeShownByGoalBlock {
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

    /// Whether a mounted goal block already shows this run's revision outcome as its card, so the header drops its copy.
    private var headerOutcomeShownByGoalBlock: Bool {
        guard let run = viewModel.selectedRun, !run.isBuilder, !viewModel.initialLoadFailed else { return false }
        let sidebar = viewModel.runSidebar
        let selectedPane = viewMode == "Graph" && !sidebar.isDefault
        return WorkflowGoalPresentation.suppressesHeaderOutcome(
            cardShown: viewModel.goalAnsweredElsewhere(for: viewModel.goalPresentation(for: run)) != nil,
            isDefaultSidebarShown: !selectedPane && WorkflowGoalPresentation.showsBlock(run: run),
            selectedPaneShowsGoal: selectedPane && sidebar.header.kind == .worker && sidebar.showsGoal)
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

// MARK: - Recovery slot

extension WorkflowView {
    /// What the run view's right-hand slot shows; the one source for drawing, summary suppression and Escape.
    var runSidebarSlot: WorkflowRunSidebarSlot {
        WorkflowRunSidebarSlot.resolve(isGraph: viewMode == "Graph", isRecoveryEligible: recoveryEligibleRunID != nil,
                                       hasNodeSelection: !viewModel.runSidebar.isDefault)
    }
}

// MARK: - WorkflowViewModel defaults

extension WorkflowViewModel {
    var validationDependencies: [String: JSONValue] { [:] }
    var branchSelection: WorkflowBranchSelection { WorkflowBranchSelection() }
}
