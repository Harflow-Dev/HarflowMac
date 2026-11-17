import HfUI
import SwiftUI

// MARK: - WorkflowTitle

/// First-save name entry; saved workflow and run titles remain static.
struct WorkflowTitle: View {
    @Binding var name: String
    let isFirstSave: Bool
    let title: String

    var body: some View {
        Group {
            if isFirstSave {
                TextField("New workflow", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Workflow name")
                    .frame(minWidth: 96, idealWidth: 260, maxWidth: 260)
            } else {
                Text(title)
            }
        }
        .font(.hf(.title, weight: .semibold))
    }
}

// MARK: - WorkflowView Title

extension WorkflowView {
    var workflowTitle: some View {
        WorkflowTitle(name: Binding(get: { viewModel.name }, set: { viewModel.name = $0 }),
                      isFirstSave: viewModel.loadedName.isEmpty && viewModel.isEditing && viewModel.selectedRun == nil,
                      title: viewModel.selectedRun?.name ?? (viewModel.isEditing ? (viewModel.name.isEmpty ? "New workflow" : viewModel.name) : "Workflows"))
    }
}

#if DEBUG
#Preview("New workflow name") {
    WorkflowTitle(name: .constant(""), isFirstSave: true, title: "New workflow")
}
#endif
