import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowInspector Branch selection

extension WorkflowInspector {
    func branchSelectionEditor(_ start: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Branch selection", selection: Binding(get: {
                start.raw["branch_selection"]?.stringValue ?? "all"
            }, set: { mode in
                guard viewModel.selectedRun == nil, !viewModel.isBusy else { return }
                viewModel.updateNode(start.id, key: "branch_selection", value: .string(mode))
            })) {
                Text("All branches").tag("all")
                Text("Orchestrator selects").tag("orchestrator")
            }
            SectionLabel(text: "Selection guidance (optional)")
            TextEditor(text: Binding(get: { start.raw["selection_guidance"]?.stringValue ?? "" }, set: { guidance in
                guard viewModel.selectedRun == nil, !viewModel.isBusy else { return }
                viewModel.updateNode(start.id, key: "selection_guidance", value: .string(guidance))
            }))
                .font(.pb(.body))
.frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .accessibilityLabel("Selection guidance")
            Text("Select applicable branch entries before dispatch. Optional steps still follow their normal failure rules.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
        }.disabled(viewModel.selectedRun != nil || viewModel.isBusy)
    }

    func branchSelectionHistory(_ start: WorkflowNodeModel, run: WorkflowRunModel) -> some View {
        let history = WorkflowGroupInvocation.history(in: run, splitID: start.id)
        let entries = WorkflowJSON.edges(run.definition).filter { $0.source == start.id && !$0.isBackward }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(history.enumerated()), id: \.element.id) { index, invocation in
                DisclosureGroup("Invocation \(history.count - index) · \(invocation.resolvedCount) of \(invocation.expectedCount) branches resolved") {
                    branchInvocationDetails(invocation, entries: entries, run: run)
                }
                .font(.pb(.secondary, weight: .medium))
            }
        }
    }

    private func branchInvocationDetails(_ invocation: WorkflowGroupInvocation, entries: [WorkflowEdgeModel], run: WorkflowRunModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { edge in
                let selected = !invocation.hasSelection || invocation.selectedConnectionIDs.contains(edge.id)
                let label = WorkflowJSON.nodes(run.definition).first { $0.id == edge.target }?.name ?? edge.target
                Text("\(label): \(selected ? "Selected" : "Not selected")")
                    .font(.pb(.secondary))
                    .foregroundStyle(selected ? Color.neutralText : Color.secondaryText)
            }
            if !invocation.reason.isEmpty {
                Text(invocation.reason).font(.pb(.secondary)).textSelection(.enabled)
            }
        }.padding(.vertical, 6)
    }

}
