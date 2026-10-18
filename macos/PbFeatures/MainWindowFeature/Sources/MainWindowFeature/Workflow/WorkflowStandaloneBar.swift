import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowStandaloneLayout

enum WorkflowStandaloneLayout {
    static var height: CGFloat {
        PbRadius.Metrics.workflowNodeSize.height + 2 * PbRadius.Metrics.spacing8 + 2 * PbRadius.Metrics.spacing12
    }
}

// MARK: - WorkflowStandaloneBar

struct WorkflowStandaloneBar<VM: WorkflowViewModel>: View {
    var viewModel: VM

    var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing16) {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                Text("Standalone").font(.pb(.secondary, weight: .semibold))
                Text("Outside the workflow path").font(.pb(.caption)).foregroundStyle(Color.tertiaryText)
            }
            ScrollView(.horizontal) {
                HStack(spacing: PbRadius.Metrics.spacing16) {
                    card(orchestrator, subtitle: orchestratorSubtitle)
                    ForEach(viewModel.standaloneNodes) { node in
                        card(node, subtitle: subtitle(node))
                    }
                    if viewModel.selectedRun == nil {
                        Button(action: viewModel.addOnDemandNode) {
                            Image(systemName: "plus")
                                .font(.pb(.title, weight: .medium))
                                .frame(width: WorkflowCanvasGeometry.size(orchestrator).height,
                                       height: WorkflowCanvasGeometry.size(orchestrator).height)
                                .overlay(RoundedRectangle(cornerRadius: PbRadius.card)
                                    .stroke(Color.accentLink, style: StrokeStyle(dash: PbRadius.Metrics.workflowPendingDash)))
                        }
.buttonStyle(.plain)
.disabled(viewModel.isBusy)
                        .help("Add on-demand node")
                        .accessibilityLabel("Add on-demand node")
                    }
                }.padding(PbRadius.Metrics.spacing8)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(colors: [.clear, Color.inspectorFill], startPoint: .leading, endPoint: .trailing)
                    .frame(width: PbRadius.Metrics.spacing16)
.allowsHitTesting(false)
            }
        }
        .padding(PbRadius.Metrics.spacing12)
        .background(Color.inspectorFill)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Standalone nodes, outside the workflow path")
    }

    private var orchestrator: WorkflowNodeModel {
        let definition = viewModel.selectedRun?.definition ?? viewModel.definition
        return WorkflowNodeModel(raw: ["id": .string(WorkflowStandalone.orchestratorID), "title": .string("Orchestrator"),
                                       "type": .string("agent"), "agent": definition["orchestrator"] ?? .object([:])])
    }

    private var orchestratorSubtitle: String {
        guard let run = viewModel.selectedRun, !run.isBuilder else { return "Decides each step" }
        let title = run.onDemandState["title"]?.stringValue ?? "node"
        switch run.onDemandState["kind"]?.stringValue {
        case "waiting": return "Waiting on \(title)"
        case "answering": return "Answering \(title)'s question"
        default: return "Deciding"
        }
    }

    private func subtitle(_ node: WorkflowNodeModel) -> String {
        guard let run = viewModel.selectedRun, !run.isBuilder else { return "On demand" }
        let count = node.raw["call_count"]?.intValue ?? 0
        if let active = node.raw["active_call_id"]?.stringValue,
           let call = viewModel.selectedRun?.onDemandCalls.first(where: { $0.id == active }) {
            return "Call \(call.number) \(call.status)"
        }
        return count == 0 ? "Not called" : "\(count) calls"
    }

    private func card(_ node: WorkflowNodeModel, subtitle: String) -> some View {
        WorkflowCanvasNode(node: node, status: node.raw["active_call_id"]?.stringValue == nil ? "pending" : "running",
                           attempt: 0, isSelected: viewModel.selectedNodeID == node.id, isEditable: false, zoom: 1,
                           childRunID: nil, onOpenRun: { _ in }, onSelect: { viewModel.selectStandalone(node.id) },
                           onMove: { _ in }, onDragEnded: {}, onConnect: {}, onRename: { _ in }, onTitleEditingChanged: { _ in },
                           isConnectionTarget: false, connectionDrag: GestureState(initialValue: nil), onDropConnectionAt: { _ in },
                           standalone: true, standaloneSubtitle: subtitle)
            .accessibilityHint(node.id == WorkflowStandalone.orchestratorID ? "Always present" : "Runs only when called")
    }
}

#if DEBUG
#Preview("Standalone nodes light") { WorkflowStandaloneBar(viewModel: WorkflowPreview.make()).preferredColorScheme(.light) }
#Preview("Standalone nodes dark") { WorkflowStandaloneBar(viewModel: WorkflowPreview.make()).preferredColorScheme(.dark) }
#endif
