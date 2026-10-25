import HfUI
import SwiftUI

// MARK: - WorkflowValidationStatus

struct WorkflowValidationStatus<VM: WorkflowViewModel>: View {
    @State var viewModel: VM

    init(viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    private var stepCount: Int { viewModel.nodes.filter { ["agent", "workflow"].contains($0.type) }.count }

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing12) {
            if let conflict = viewModel.editorConflict {
                Text(conflict).font(.hf(.caption)).lineLimit(2).help(conflict)
                Button("Save copy and reload") { viewModel.preserveDraftAndReload() }
            } else if let message = viewModel.validationMessage, !message.isEmpty {
                Text(message + " · \(stepCount) nodes · \(viewModel.standaloneNodes.count) on demand")
                    .font(.hf(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help(message)
                    .padding(.horizontal, HfRadius.Metrics.spacing12)
                    .padding(.vertical, HfRadius.Metrics.spacing6)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Text("Drag nodes onto the canvas; connect their dots.")
                    .font(.hf(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help("Drag an output dot to an input, or click the output then the destination. "
                          + "Select a node and press Delete to remove it.")
            }
            if !viewModel.missingReferences.isEmpty {
                Menu("Review missing workflows") {
                    if viewModel.missingReferencesTruncated {
                        Text("Additional missing references may remain; validate again after repairs.")
                    }
                    ForEach(Array(viewModel.missingReferences.enumerated()), id: \.offset) { _, reference in
                        let path = WorkflowJSON.objects(reference["dependency_path"])
                        let rootNode = path.first?["node_id"]?.stringValue ?? reference["node_id"]?.stringValue ?? ""
                        let title = path.compactMap { $0["node_title"]?.stringValue ?? $0["node_id"]?.stringValue }.joined(separator: " → ")
                        Button(title.isEmpty ? rootNode : title) { viewModel.selectNode(rootNode) }
                    }
                }
            }
            Spacer(minLength: HfRadius.Metrics.zero)
            if viewModel.connectionSourceID != nil {
                Button("Cancel connection") { viewModel.connectionSourceID = nil }
                    .buttonStyle(MonitorButtonStyle(.glass))
            }
        }
    }

}

#if DEBUG
#Preview("Workflow validation") {
    WorkflowValidationStatus(viewModel: WorkflowPreview.make(run: false))
}
#endif
