import MonitorCore
import PbCommon
import SwiftUI

// MARK: - Workflow activity selection

extension WorkflowView {
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
            initialLoadFailed: viewModel.initialLoadFailed)
    }
}

// MARK: - WorkflowViewModel defaults

extension WorkflowViewModel {
    var validationDependencies: [String: JSONValue] { [:] }
    var branchSelection: WorkflowBranchSelection { WorkflowBranchSelection() }
}
