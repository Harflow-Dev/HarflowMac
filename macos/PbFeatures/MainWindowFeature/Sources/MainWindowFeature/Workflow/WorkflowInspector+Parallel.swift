import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowInspector Parallel

extension WorkflowInspector {
    func parallelEditor(_ node: WorkflowNodeModel) -> some View {
        let nodes = WorkflowJSON.nodes(inspectorDefinition)
        let edges = WorkflowJSON.edges(inspectorDefinition)
        let partner = WorkflowParallelGroup.partner(of: node, nodes: nodes)
        let start = node.type == "parallel_start" ? node : partner
        let branches = edges.filter { $0.source == start?.id && !$0.isBackward }.count
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: WorkflowRole.title(node.type))
            TextField("Group name", text: Binding(get: { node.raw["group_label"]?.stringValue ?? "" }, set: { label in
                guard viewModel.selectedRun == nil, !viewModel.isBusy else { return }
                let updated = nodes.map { boundary -> JSONValue in
                    var raw = boundary.raw
                    if boundary.parallelGroupID == node.parallelGroupID { raw["group_label"] = .string(label) }
                    return .object(raw)
                }
                viewModel.definition["nodes"] = .array(updated)
            }))
.textFieldStyle(.roundedBorder)
.disabled(viewModel.selectedRun != nil || viewModel.isBusy)
            Text("\(branches) branches").font(.pb(.secondary))
            if let run = viewModel.selectedRun, let start {
                let generations = run.raw["joins"]?.objectValue?.values.compactMap(\.objectValue) ?? []
                let waiting = generations.filter { $0["split_id"]?.stringValue == start.id }
                ForEach(Array(waiting.enumerated()), id: \.offset) { _, generation in
                    let completed = generation["arrival_ids"]?.arrayValue?.count ?? 0
                    let expected = generation["expected"]?.intValue ?? branches
                    Text("\(completed) of \(expected) branches resolved").font(.pb(.secondary))
                }
                let released = run.raw["released_parallel_groups"]?
.objectValue?
.values
.compactMap(\.objectValue)
                    .filter { $0["split_id"]?.stringValue == start.id } ?? []
                if !released.isEmpty { Text("\(released.count) completed group executions").font(.pb(.secondary)) }
            }
            if let partner {
                Button("Select " + WorkflowRole.title(partner.type)) { viewModel.selectNode(partner.id) }
                    .buttonStyle(QuietButtonStyle())
            } else {
                Text("Missing matching parallel boundary. Repair the pair before saving.")
                    .foregroundStyle(Color.warningFG)
            }
            Text(node.type == "parallel_start" ? "Runs every outgoing branch. Conditions for choosing this group belong on its incoming connection."
                 : "Waits for all branches to resolve before the orchestrator chooses the next step.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            if viewModel.selectedRun == nil {
                Button("Delete boundary", role: .destructive) { viewModel.deleteSelected() }
            }
        }.font(.pb(.body))
    }

}
