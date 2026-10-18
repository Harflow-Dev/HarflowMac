import PbUI
import SwiftUI

// MARK: - WorkflowValidationStatus

struct WorkflowValidationStatus<VM: WorkflowViewModel>: View {
    @State var viewModel: VM

    init(viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    private var stepCount: Int { viewModel.nodes.filter { ["agent", "workflow"].contains($0.type) }.count }

    var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing12) {
            if let conflict = viewModel.editorConflict {
                Text(conflict).font(.pb(.caption)).lineLimit(2).help(conflict)
                Button("Save copy and reload") { viewModel.preserveDraftAndReload() }
            } else if let message = viewModel.validationMessage, !message.isEmpty {
                Text(message + " · \(stepCount) steps · \(viewModel.standaloneNodes.count) on demand")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help(message)
                    .padding(.horizontal, PbRadius.Metrics.spacing12)
                    .padding(.vertical, PbRadius.Metrics.spacing6)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Text("Drag steps onto the canvas; connect their dots.")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help("Drag an output dot to an input, or click the output then the destination. "
                          + "Select a step and press Delete to remove it.")
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
            Spacer(minLength: PbRadius.Metrics.zero)
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
