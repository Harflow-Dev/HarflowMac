import HfUI
import SwiftUI

// MARK: - WorkflowSaveButton

struct WorkflowSaveButton: View {
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: @MainActor () -> Void

    var body: some View {
        Button("Save", action: action)
            .buttonStyle(QuietButtonStyle(isFilled: false))
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - WorkflowView Save

extension WorkflowView {
    /// The editor's Save action, shared by the production header and hosted presentation checks.
    var saveButton: some View {
        WorkflowSaveButton(isEnabled: viewModel.canSave, accessibilityLabel: viewModel.validationState.saveAccessibilityLabel) {
            viewModel.save()
        }
    }
}

#if DEBUG
#Preview("Workflow Save") {
    WorkflowSaveButton(isEnabled: false, accessibilityLabel: "Save") {}
}
#endif
