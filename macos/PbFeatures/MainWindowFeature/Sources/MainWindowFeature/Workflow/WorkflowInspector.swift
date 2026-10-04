import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowInspector

struct WorkflowInspector<VM: WorkflowViewModel>: View {
    var viewModel: VM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let node = viewModel.selectedNode {
                    if node.isParallelBoundary {
                        parallelEditor(node)
                    } else if let run = viewModel.selectedRun, !run.isBuilder {
                        nodeHistory(node)
                    } else if node.type == "start" {
                        workflowEditor.disabled(viewModel.selectedRun != nil)
                    } else {
                        nodeEditor(node).disabled(viewModel.selectedRun != nil || viewModel.isBusy)
                    }
                } else if let edge = viewModel.selectedEdge {
                    edgeEditor(edge)
                } else {
                    workflowEditor.disabled(viewModel.selectedRun != nil)
                }
            }.padding(16)
        }.background(Color.cardFill)
    }

    var inspectorDefinition: [String: JSONValue] {
        viewModel.selectedRun?.definition ?? viewModel.definition
    }

    private var workflowEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "Workflow")
            TextField("Workflow name", text: Binding(get: { inspectorDefinition["name"]?.stringValue ?? viewModel.name }, set: {
                    guard viewModel.selectedRun == nil else { return }
                    viewModel.name = $0
                }))
.textFieldStyle(.roundedBorder)
                .disabled(!viewModel.loadedName.isEmpty)
            TextField(
                "Description",
                text: Binding(get: { inspectorDefinition["description"]?.stringValue ?? "" }, set: {
                    guard viewModel.selectedRun == nil else { return }
                    viewModel.definition["description"] = .string($0)
                }),
                axis: .vertical
            )
                .textFieldStyle(.roundedBorder)
            if let start = WorkflowJSON.objects(inspectorDefinition["nodes"]).first(where: { $0["type"]?.stringValue == "start" }),
               let startID = start["id"]?.stringValue {
                SectionLabel(text: "Workflow prompt (optional)")
                TextEditor(text: Binding(get: {
                    WorkflowJSON.objects(inspectorDefinition["nodes"]).first { $0["id"]?.stringValue == startID }?["prompt"]?.stringValue ?? ""
                }, set: {
                    guard viewModel.selectedRun == nil else { return }
                    viewModel.updateNode(startID, key: "prompt", value: .string($0))
                }))
                    .font(.pb(.body))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                    .accessibilityLabel("Workflow prompt")
                Text("Describe the workflow's purpose to guide the orchestrator.")
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            SectionLabel(text: "Orchestrator")
            WorkflowAgentEditor(
                candidate: Binding(
                    get: { inspectorDefinition["orchestrator"]?.objectValue ?? ["backend": .string("codex")] },
                    set: {
                    guard viewModel.selectedRun == nil else { return }
                    viewModel.definition["orchestrator"] = .object($0)
                    }
                ),
                backendIDs: viewModel.backendIDs,
                modelChoices: viewModel.modelChoices,
                loadModels: viewModel.loadModels
            )
            Stepper("Decision attempts: \(integer("max_decision_attempts", default: 3))", value: intBinding("max_decision_attempts", default: 3), in: 1 ... 10)
            Stepper("Inspections: \(integer("max_inspections", default: 20))", value: intBinding("max_inspections", default: 20), in: 1 ... 1000)
            Stepper("Parallel agents: \(integer("max_parallel", default: 4))", value: intBinding("max_parallel", default: 4), in: 1 ... 64)
            Stepper("Transition limit: \(integer("max_transitions", default: 100))", value: intBinding("max_transitions", default: 100), in: 1 ... 10000)
            Text("Select a node or connection to edit its instructions and conditions.").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }.font(.pb(.body))
    }

    @ViewBuilder
    private func nextPathHint(_ node: WorkflowNodeModel) -> some View {
        if node.type != "end", WorkflowJSON.edges(inspectorDefinition).filter({ $0.source == node.id }).count > 1 {
            Text("Choose exactly one next path").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    private func nodeEditor(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(text: node.type == "agent" ? node.role.capitalized : WorkflowRole.title(node.type))
                Spacer()
                Button(role: .destructive) { viewModel.deleteSelected() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
.accessibilityLabel("Delete step")
            }
            nextPathHint(node)
            if node.type == "agent" {
                TextField("Step name", text: nodeString(node, "title")).textFieldStyle(.roundedBorder)
                Picker("Role", selection: nodeString(node, "role", default: "task")) {
                    ForEach(["planning", "implementation", "review", "task"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Optional", isOn: Binding(get: { viewModel.selectedNode?.isOptional ?? false }, set: {
                    guard viewModel.selectedRun == nil, !viewModel.isBusy else { return }
                    viewModel.updateNode(node.id, key: "optional", value: .bool($0))
                }))
                Text("Continue if this step fails within a parallel branch. Required branches must succeed.")
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                SectionLabel(text: "Instructions")
                TextEditor(text: nodeString(node, "instructions"))
.font(.pb(.body))
.frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                    .accessibilityLabel("Step instructions")
                WorkflowAgentEditor(
                    candidate: Binding(
                        get: { viewModel.selectedNode?.raw["agent"]?.objectValue ?? ["backend": .string("codex")] },
                        set: { viewModel.updateNode(node.id, key: "agent", value: .object($0)) }
                    ),
                    backendIDs: viewModel.backendIDs,
                    modelChoices: viewModel.modelChoices,
                    loadModels: viewModel.loadModels
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session").fixedSize(horizontal: true, vertical: false)
                    Picker("Session", selection: nodeString(node, "session_mode", default: "agent_decides")) {
                        Text("Let agent decide").tag("agent_decides")
                        Text("Resume").tag("resume")
                        Text("Fresh").tag("fresh")
                    }
.labelsHidden()
.pickerStyle(.segmented)
                }
                Stepper("Attempt limit: \(node.raw["max_attempts"]?.intValue ?? 3)", value: Binding(get: {
                    viewModel.selectedNode?.raw["max_attempts"]?.intValue ?? 3
                }, set: { viewModel.updateNode(node.id, key: "max_attempts", value: .number(Double($0))) }), in: 1 ... 10000)
                Stepper("Context questions: \(node.raw["max_context_questions"]?.intValue ?? 10)", value: Binding(get: {
                    viewModel.selectedNode?.raw["max_context_questions"]?.intValue ?? 10
                }, set: { viewModel.updateNode(node.id, key: "max_context_questions", value: .number(Double($0))) }), in: 1 ... 100)
                Picker("Access", selection: nodeString(node, "freedom", default: WorkflowAccess.defaultLevel(for: node.role))) {
                    ForEach(WorkflowAccess.allowedLevels(for: node.role), id: \.self) { level in
                        Text(WorkflowAccess.title(level)).tag(level)
                    }
                }
            }
        }.font(.pb(.body))
    }

    private func edgeEditor(_ edge: WorkflowEdgeModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(text: "Connection")
                Spacer()
                if viewModel.selectedRun == nil {
                    Button(role: .destructive) { viewModel.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
.accessibilityLabel("Delete connection")
                }
            }
            Text("\(edge.source) → \(edge.target)").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            Text(WorkflowJSON.nodes(inspectorDefinition).first { $0.id == edge.source }?.type == "parallel_start" ? "Branch purpose" : "Condition")
                .font(.pb(.body, weight: .medium))
            TextEditor(text: Binding(get: { viewModel.selectedEdge?.condition ?? "" }, set: {
                viewModel.updateEdge(edge.id, key: "condition", value: .string($0))
            }))
.font(.pb(.body))
.frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .accessibilityLabel("Connection condition")
            Toggle("Default path", isOn: Binding(get: { viewModel.selectedEdge?.isDefault ?? false }, set: {
                viewModel.updateEdge(edge.id, key: "default", value: .bool($0))
            }))
            if edge.isBackward || edge.maxRetries != nil {
                retryLimit(edge)
            }
            Text("The orchestrator chooses exactly one outgoing path from ordinary nodes. "
                 + "Parallel start runs every branch; its matching Parallel end waits for all branches. "
                 + "Returning to an earlier step creates a loop automatically; "
                 + "Polybridge enforces connected paths and attempt limits.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
        }
        .disabled(viewModel.selectedRun != nil)
    }

    private func retryLimit(_ edge: WorkflowEdgeModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Limit retries", isOn: Binding(get: { viewModel.selectedEdge?.maxRetries != nil }, set: {
                viewModel.updateEdge(edge.id, key: "max_retries", value: $0 ? .number(3) : nil)
            }))
            if edge.maxRetries != nil {
                Stepper("Max retries: \(edge.maxRetries ?? 3)", value: Binding(get: { viewModel.selectedEdge?.maxRetries ?? 3 }, set: {
                    viewModel.updateEdge(edge.id, key: "max_retries", value: .number(Double($0)))
                }), in: 0 ... 1000).disabled(!edge.isBackward)
                Text(edge.isBackward ? "0 disables this retry. Node attempt and workflow limits still apply."
                     : "This limit applies when the connection returns to an earlier step.")
                    .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func nodeHistory(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: node.name)
            if node.type == "agent" {
                Text(node.isOptional ? "Optional step" : "Required step")
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            Text(node.instructions).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            Button("Show latest steps") { viewModel.selectActivation(nil) }.buttonStyle(QuietButtonStyle())
            ForEach(Array((viewModel.selectedRun?.activations.filter {
                $0["node_id"]?.stringValue == node.id
            } ?? []).enumerated()), id: \.offset) { index, activation in
                VStack(alignment: .leading, spacing: 8) {
                    let label = activation["role"]?.stringValue == "orchestrator" ? "Decision" : "Attempt"
                    Text("\(label) \(index + 1) · \(activation["status"]?.stringValue ?? "")")
                        .font(.pb(.secondary, weight: .semibold))
                    if let error = activation["result_error"]?.stringValue {
                        Text(error).font(.pb(.secondary)).foregroundStyle(Color.warningFG).textSelection(.enabled)
                    }
                    if let retryOf = activation["retry_of_execution_id"]?.stringValue {
                        Text("Retry of execution " + retryOf).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                    if let assignment = activation["assignment_prompt"]?.stringValue {
                        Text("Assignment").font(.pb(.secondary, weight: .semibold))
                        Text(assignment).font(.pb(.secondary)).textSelection(.enabled)
                    }
                    ForEach(Array(WorkflowJSON.objects(activation["questions"]).enumerated()), id: \.offset) { _, question in
                        Text("Question: " + (question["question"]?.stringValue ?? "")).font(.pb(.secondary)).textSelection(.enabled)
                        if let context = question["context"]?.stringValue { Text(context).font(.pb(.secondary)).textSelection(.enabled) }
                        if let answer = question["answer"]?.stringValue {
                            Text("Answer: " + answer).font(.pb(.secondary)).textSelection(.enabled)
                        }
                    }
                    if let result = activation["node_result"], let description = WorkflowNodePresentation.summary(result.rendered()) {
                        Text("Result").font(.pb(.secondary, weight: .semibold))
                        Text(description).font(.pb(.secondary)).textSelection(.enabled)
                    }
                    if activation["role"]?.stringValue == "node", let id = activation["id"]?.stringValue {
                        Button("Show activity") { viewModel.selectActivation(id) }.buttonStyle(QuietButtonStyle())
                    }
                    ForEach(Array(WorkflowJSON.objects(activation["tasks"]).enumerated()), id: \.offset) { _, task in
                        let attempt = WorkflowExecutionAttempts.fallbackIndices(activation)[task["task_id"]?.stringValue ?? ""] ?? 0
                        HStack(alignment: .top, spacing: 6) {
                            BackendDot(backend: task["candidate"]?["backend"]?.stringValue ?? "")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(attempt == 0 ? "Primary" : "Fallback \(attempt)"): \(task["candidate"]?["backend"]?.stringValue ?? "agent")")
                                Text(task["status"]?.stringValue ?? "").foregroundStyle(Color.secondaryText)
                                if let reason = task["reason"]?.stringValue {
                                    Text(reason).foregroundStyle(Color.secondaryText)
                                }
                            }.font(.pb(.caption))
                        }
                    }
                }
.padding(10)
.background(Color.composerFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
            }
        }
    }

    private func nodeString(_ node: WorkflowNodeModel, _ key: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { viewModel.selectedNode?.raw[key]?.stringValue ?? fallback }, set: {
            viewModel.updateNode(node.id, key: key, value: $0.isEmpty && key == "join_id" ? nil : .string($0))
        })
    }

    private func integer(_ key: String, default fallback: Int) -> Int { inspectorDefinition[key]?.intValue ?? fallback }
    private func intBinding(_ key: String, default fallback: Int) -> Binding<Int> {
        Binding(get: { integer(key, default: fallback) }, set: {
                    guard viewModel.selectedRun == nil else { return }
                    viewModel.definition[key] = .number(Double($0))
                })
    }
}

#if DEBUG
#Preview("Workflow inspector") {
    WorkflowInspector(viewModel: WorkflowPreview.make()).frame(width: 300, height: 650)
}
#endif
