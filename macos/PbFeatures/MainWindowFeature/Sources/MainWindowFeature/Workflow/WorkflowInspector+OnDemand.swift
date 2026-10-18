import MonitorCore
import PbUI
import SwiftUI

// MARK: - On-demand inspector

extension WorkflowInspector {
    func onDemandEditor(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
            HStack {
                SectionLabel(text: "On-demand node")
                Spacer()
                Button("Remove", role: .destructive) { viewModel.deleteSelected() }.disabled(viewModel.selectedRun != nil)
            }
            TextField("Node name", text: standaloneString(node, "title")).textFieldStyle(.roundedBorder)
            SectionLabel(text: "When to call")
            TextEditor(text: standaloneString(node, "call_condition"))
                .font(.pb(.body))
.scrollChromeScope()
                .frame(minHeight: PbRadius.Metrics.recoveryEditorMaximumHeight)
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .accessibilityLabel("When to call")
            Text("The orchestrator reads this guidance to decide when to call the node.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            SectionLabel(text: "Instructions")
            TextEditor(text: standaloneString(node, "instructions"))
                .font(.pb(.body))
.scrollChromeScope()
                .frame(minHeight: PbRadius.Metrics.recoveryEditorMaximumHeight)
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .accessibilityLabel("Worker instructions")
            WorkflowAgentEditor(candidate: Binding(get: { current(node).raw["agent"]?.objectValue ?? [:] }, set: {
                viewModel.updateNode(node.id, key: "agent", value: .object($0))
            }), backendIDs: viewModel.backendIDs, modelChoices: viewModel.modelChoices,
                loadModels: viewModel.loadModels, callerApprovalBackends: viewModel.callerApprovalBackends)
            SectionLabel(text: "When called")
            Picker("Access", selection: standaloneString(node, "freedom", default: "read_only")) {
                ForEach(WorkflowAccess.allowedLevels(for: "task"), id: \.self) { Text(WorkflowAccess.title($0)).tag($0) }
            }
            Picker("Network", selection: Binding(get: { current(node).raw["network"]?.boolValue.map { $0 ? "on" : "off" } ?? "inherit" }, set: {
                viewModel.updateNode(node.id, key: "network", value: $0 == "inherit" ? nil : .bool($0 == "on"))
            })) {
                Text("Inherit").tag("inherit"); Text("On").tag("on"); Text("Off").tag("off")
            }
            Picker("Session", selection: standaloneString(node, "session_mode", default: "agent_decides")) {
                Text("Agent decides").tag("agent_decides"); Text("Fresh").tag("fresh"); Text("Resume").tag("resume")
            }
            Picker("Execution", selection: standaloneString(node, "execution_mode", default: "headless")) {
                Text("Headless").tag("headless"); Text("Prefer orchestrator subagent").tag("prefer_subagent")
            }
            Text("No connections. It runs only when the orchestrator calls it, one call at a time, and an unused node never blocks the run from finishing.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
        }
    }

    private func current(_ node: WorkflowNodeModel) -> WorkflowNodeModel { viewModel.selectedOnDemandNode ?? node }
    private func standaloneString(_ node: WorkflowNodeModel, _ key: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { current(node).raw[key]?.stringValue ?? fallback }, set: { viewModel.updateNode(node.id, key: key, value: .string($0)) })
    }
}
