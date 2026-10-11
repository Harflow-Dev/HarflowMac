import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowInspector

struct WorkflowInspector<VM: WorkflowViewModel>: View {
    var viewModel: VM
    var isScrollable = true
    @State private var timeoutUnit: WorkflowTimeoutUnit = .minutes

    var body: some View {
        Group {
            if isScrollable {
                // The document probe (§6.3): inside the inspector's own document, so it can only
                // ever target this outer scroll view — never a nested editor's.
                ScrollView { content.background(ScrollChrome()) }
            } else {
                content
            }
        }
        // The flush-pane amendment (user override of SPEC §6.3): a plain cardFill panel
        // edge-to-edge, as before the redesign — no rounded surround or border.
        .background(Color.cardFill)
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
                if let permissions = viewModel.selectedRun?.orchestratorPermissions {
                    WorkflowPermissionsView(model: permissions)
                }
                if let policy = viewModel.selectedRun?.schedulingPolicyDescription {
                    Text(policy).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                }
                if let node = viewModel.selectedNode {
                    if node.isParallelBoundary {
                        parallelEditor(node)
                    } else if let run = viewModel.selectedRun, !run.isBuilder {
                        nodeHistory(node)
                    } else if node.type == "workflow" {
                        workflowNodeEditor(node).disabled(viewModel.selectedRun != nil || viewModel.isBusy)
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
            }
            .padding(PbRadius.Metrics.spacing16)
    }

    var inspectorDefinition: [String: JSONValue] {
        viewModel.selectedRun?.definition ?? viewModel.definition
    }

    private var workflowEditor: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
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
                // Bounded scope (§6.3): the multiline description's own dedicated scroll view,
                // when one exists; a quiet no-op otherwise, the shared field editor untouched.
                .scrollChromeScope()
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
                    // Bounded scope (§6.3): the prompt editor's own scroll view, when one exists.
                    .scrollChromeScope()
                    .frame(minHeight: PbRadius.Metrics.recoveryEditorMaximumHeight)
                    .overlay(alignment: .topLeading) {
                        // The existing helper text becomes the empty editor's overlay and the
                        // field's accessibility hint; the binding is unchanged.
                        let prompt = WorkflowJSON.objects(inspectorDefinition["nodes"])
                            .first { $0["id"]?.stringValue == startID }?["prompt"]?
.stringValue ?? ""
                        if prompt.isEmpty {
                            Text("Describe the workflow's purpose to guide the orchestrator.")
                                .font(.pb(.body))
                                .foregroundStyle(Color.tertiaryText)
                                .padding(.top, PbRadius.Metrics.spacing8)
                                .padding(.leading, PbRadius.Metrics.spacing6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                    .accessibilityLabel("Workflow prompt")
                    .accessibilityHint("Describe the workflow's purpose to guide the orchestrator.")
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
            SectionLabel(text: "Limits")
            WorkflowFormGroup {
                WorkflowFormRow(label: "Decision attempts") {
                    WorkflowCompactStepper(label: "Decision attempts",
                                           value: intBinding("max_decision_attempts", default: 3),
                                           range: 1 ... 10)
                }
                WorkflowFormDivider()
                WorkflowFormRow(label: "Inspections") {
                    WorkflowCompactStepper(label: "Inspections",
                                           value: intBinding("max_inspections", default: 20),
                                           range: 1 ... 1000)
                }
                WorkflowFormDivider()
                WorkflowFormRow(label: "Parallel agents") {
                    WorkflowCompactStepper(label: "Parallel agents",
                                           value: intBinding("max_parallel", default: 4),
                                           range: 1 ... 64)
                }
                WorkflowFormDivider()
                WorkflowFormRow(label: "Transition limit") {
                    WorkflowCompactStepper(label: "Transition limit",
                                           value: intBinding("max_transitions", default: 100),
                                           range: 1 ... 10000)
                }
            }
            Text("Select a node or connection to edit its instructions and conditions.")
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
                .padding(PbRadius.Metrics.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row)
                    .stroke(Color.cardBorder, style: StrokeStyle(lineWidth: PbRadius.Metrics.hairlineStroke, dash: PbRadius.Metrics.workflowPendingDash)))
        }.font(.pb(.body))
    }

    @ViewBuilder
    private func nextPathHint(_ node: WorkflowNodeModel) -> some View {
        if node.type != "end", WorkflowJSON.edges(inspectorDefinition).filter({ $0.source == node.id }).count > 1 {
            Text("Choose exactly one next path").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder
    private func technicalPlanSetting(_ node: WorkflowNodeModel) -> some View {
        if node.role == "planning" {
            Toggle("Require task list", isOn: Binding(get: {
                viewModel.selectedNode?.raw["require_tasks"]?.boolValue ?? true
            }, set: { viewModel.updateNode(node.id, key: "require_tasks", value: .bool($0)) }))
            Toggle("Require technical plan", isOn: Binding(get: {
                viewModel.selectedNode?.raw["require_technical_plan"]?.boolValue ?? true
            }, set: { viewModel.updateNode(node.id, key: "require_technical_plan", value: .bool($0)) }))
            Text("Disable both for a brief result without replacing the run's existing plan or task list.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
        }
    }

    private func workflowNodeEditor(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
            HStack {
                SectionLabel(text: "Run workflow")
                Spacer()
                Button(role: .destructive) { viewModel.deleteSelected() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete step")
            }
            TextField("Step name", text: nodeString(node, "title")).textFieldStyle(.roundedBorder)
            Picker("Saved workflow", selection: Binding(get: { node.workflowID }, set: { id in
                viewModel.updateNode(node.id, key: "workflow_ref", value: .object(["workflow_id": .string(id)]))
                viewModel.updateNode(node.id, key: "workflow_name", value: .string(viewModel.workflows.first { $0.workflowID == id }?.id ?? ""))
            })) {
                Text("Select workflow").tag("")
                if !node.workflowID.isEmpty, !viewModel.workflows.contains(where: { $0.workflowID == node.workflowID }) {
                    Text("Unavailable workflow").tag(node.workflowID)
                }
                ForEach(viewModel.workflows.filter { !$0.workflowID.isEmpty }) { record in
                    Text(record.id).tag(record.workflowID)
                }
            }
            Picker("Orchestrator mode", selection: nodeString(node, "orchestrator_mode", default: "child")) {
                Text("Child orchestrator").tag("child")
                Text("Current orchestrator").tag("current")
            }
            childSessionSetting(node)
            Text(node.orchestratorMode == "current"
                ? "The current orchestrator directs the child's nodes in its own workflow boundary."
                : "The child uses its saved orchestrator and its own planning context.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            SectionLabel(text: "Assignment guidance")
            TextEditor(text: nodeString(node, "instructions"))
                .font(.pb(.body))
                // Bounded scope (§6.3): the instructions editor's own scroll view, if one exists.
                .scrollChromeScope()
.frame(minHeight: PbRadius.Metrics.recoveryEditorMaximumHeight)
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .accessibilityLabel("Assignment guidance")
            Toggle("Optional", isOn: Binding(get: { node.isOptional }, set: {
                viewModel.updateNode(node.id, key: "optional", value: .bool($0))
            }))
            Text("Optional branches follow the workflow's failure safety rules.").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            timeoutSetting(node)
            Stepper("Attempts per visit: \(node.raw["max_attempts"]?.intValue ?? 3)", value: Binding(get: {
                viewModel.selectedNode?.raw["max_attempts"]?.intValue ?? 3
            }, set: { viewModel.updateNode(node.id, key: "max_attempts", value: .number(Double($0))) }), in: 1 ... 10000)
            savedWorkflowAccess
            Text("Harness, access, network and session settings remain owned by the saved child workflows.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            if let message = viewModel.validationMessage { Text(message).font(.pb(.secondary)).foregroundStyle(Color.failedRed) }
            nextPathHint(node)
        }.font(.pb(.body))
    }

    private var savedWorkflowAccess: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            SectionLabel(text: "Workflow tree access requirements")
            if let access = viewModel.validationDependencies["access"]?.objectValue {
                ForEach(access.keys.sorted(), id: \.self) { id in
                    let requirement = access[id]
                    let label = viewModel.validationDependencies["workflows"]?[id]?["name"]?.stringValue ?? id
                    let freedom = WorkflowAccess.title(requirement?["max_freedom"]?.stringValue ?? "read_only")
                    let network = requirement?["network"]?.boolValue == true ? " · Network" : ""
                    Text("\(label): \(freedom)\(network)")
                        .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                }
            } else {
                Text("Select a saved workflow to validate its full dependency tree.").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func nodeEditor(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
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
                technicalPlanSetting(node)
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
                    // Bounded scope (§6.3): the instructions editor's own scroll view, if one exists.
                    .scrollChromeScope()
.frame(minHeight: PbRadius.Metrics.recoveryEditorMaximumHeight)
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
                executionSetting(node)
                sessionSetting(node)
                timeoutSetting(node)
                Stepper("Attempts per visit: \(node.raw["max_attempts"]?.intValue ?? 3)", value: Binding(get: {
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

    private func executionSetting(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            Picker("Execution", selection: nodeString(node, "execution_mode", default: "headless")) {
                Text("Headless").tag("headless")
                Text("Prefer orchestrator subagent")
.tag("prefer_subagent")
            }
            Text(viewModel.nativeSubagentsAvailable
                 ? "Uses the owning orchestrator when the harness and settings are supported; otherwise starts Headless."
                 : "No certified native adapter is available. This preference falls back to Headless.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
        }
    }

    private func sessionSetting(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            Text("Session").fixedSize(horizontal: true, vertical: false)
            Picker("Session", selection: nodeString(node, "session_mode", default: "agent_decides")) {
                Text("Let agent decide").tag("agent_decides")
                Text("Resume this node").tag("resume")
                Text("Fresh").tag("fresh")
                Text("Continue previous node")
.tag("continue_previous")
                    .disabled(!WorkflowNodeExecutionSettings.canContinuePrevious(node, definition: inspectorDefinition))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if node.raw["session_mode"]?.stringValue == "continue_previous" {
                Text("Reuse the previous serial node's compatible session. Otherwise start Fresh; fallbacks also start Fresh.")
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func timeoutSetting(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            Toggle("Time limit", isOn: Binding(get: {
                viewModel.selectedNode.map { WorkflowNodeExecutionSettings.timeoutSeconds($0) != nil } ?? false
            }, set: { enabled in
                viewModel.updateNode(node.id, key: "timeout_seconds", value: enabled ? .number(900) : nil)
            }))
            if WorkflowNodeExecutionSettings.timeoutSeconds(node) != nil {
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    TextField("Duration", value: Binding(get: {
                        timeoutUnit.value(for: viewModel.selectedNode.flatMap(WorkflowNodeExecutionSettings.timeoutSeconds) ?? 900)
                    }, set: { value in
                        guard let seconds = timeoutUnit.seconds(for: value) else { return }
                        viewModel.updateNode(node.id, key: "timeout_seconds", value: .number(Double(seconds)))
                    }), format: .number.grouping(.never).precision(.fractionLength(0 ... 6)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: PbRadius.Metrics.workflowFieldValueWidth)
                        .accessibilityLabel("Time limit duration")
                    Picker("Unit", selection: $timeoutUnit) {
                        ForEach(WorkflowTimeoutUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
.labelsHidden()
.pickerStyle(.menu)
                    Stepper("Adjust duration", value: Binding(get: {
                        timeoutUnit.value(for: viewModel.selectedNode.flatMap(WorkflowNodeExecutionSettings.timeoutSeconds) ?? 900)
                    }, set: { value in
                        guard let seconds = timeoutUnit.seconds(for: value) else { return }
                        viewModel.updateNode(node.id, key: "timeout_seconds", value: .number(Double(seconds)))
                    }), in: (1 / timeoutUnit.multiplier) ... (86400 / timeoutUnit.multiplier), step: 1)
                        .labelsHidden()
                }
                Text("Stop and settle the attempt before retrying or using a fallback.")
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            }
        }.onChange(of: node.id, initial: true) { _, _ in
            timeoutUnit = .preferred(for: WorkflowNodeExecutionSettings.timeoutSeconds(node) ?? 900)
        }
    }

    private func edgeEditor(_ edge: WorkflowEdgeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
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
                // Bounded scope (§6.3): the condition editor's own scroll view, if one exists.
                .scrollChromeScope()
.frame(minHeight: PbRadius.Metrics.taskSkeletonStatusWidth)
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
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
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
    WorkflowInspector(viewModel: WorkflowPreview.make())
        .frame(width: PbRadius.Metrics.formPreviewWidth,
                height: PbRadius.Metrics.workflowInspectorPreviewHeight)
}

#Preview("Workflow inspector - dark") {
    WorkflowInspector(viewModel: WorkflowPreview.make())
        .frame(width: PbRadius.Metrics.formPreviewWidth,
                height: PbRadius.Metrics.workflowInspectorPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Workflow inspector - selected node") {
    let vm = WorkflowPreview.make()
    vm.selectedNodeID = vm.nodes.first { $0.type == "agent" }?.id
    return WorkflowInspector(viewModel: vm).frame(width: PbRadius.Metrics.formPreviewWidth, height: PbRadius.Metrics.workflowInspectorPreviewHeight)
}

#Preview("Workflow inspector - selected connection") {
    let vm = WorkflowPreview.make()
    vm.selectedEdgeID = vm.edges.first?.id
    return WorkflowInspector(viewModel: vm)
        .frame(width: PbRadius.Metrics.formPreviewWidth,
                height: PbRadius.Metrics.workflowInspectorPreviewHeight)
        .preferredColorScheme(.dark)
}

/// A parallel boundary pair selected: the branch-selection editor (and its scoped guidance
/// editor) render inside the parallel panel. Dummy preview data only.
@MainActor
private func makeParallelBoundaryPreviewVM() -> WorkflowVM {
    let vm = WorkflowPreview.make()
    var nodes = WorkflowJSON.objects(vm.definition["nodes"])
    nodes.append([
        "id": .string("preview-parallel-start"), "title": .string("Parallel"),
        "type": .string("parallel_start"), "parallel_group_id": .string("preview-group")
    ])
    nodes.append([
        "id": .string("preview-parallel-end"), "title": .string("Parallel"),
        "type": .string("parallel_end"), "parallel_group_id": .string("preview-group")
    ])
    vm.definition["nodes"] = .array(nodes.map(JSONValue.object))
    vm.selectedNodeID = "preview-parallel-start"
    return vm
}

#Preview("Workflow inspector - parallel branch selection - light") {
    WorkflowInspector(viewModel: makeParallelBoundaryPreviewVM())
        .frame(width: PbRadius.Metrics.formPreviewWidth,
                height: PbRadius.Metrics.workflowInspectorPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow inspector - parallel branch selection - dark") {
    WorkflowInspector(viewModel: makeParallelBoundaryPreviewVM())
        .frame(width: PbRadius.Metrics.formPreviewWidth,
                height: PbRadius.Metrics.workflowInspectorPreviewHeight)
        .preferredColorScheme(.dark)
}
#endif

// MARK: - Child conversation settings and invocation details

extension WorkflowInspector {
    @ViewBuilder
    private func childSessionSetting(_ node: WorkflowNodeModel) -> some View {
        if node.showsChildSessionPolicy {
            Picker("Child conversation", selection: nodeString(node, "child_session_policy", default: "agent_decides")) {
                Text("Fresh").tag("fresh")
                Text("Resume").tag("resume")
                Text("Agent decides").tag("agent_decides")
            }
            Text("Resume reuses the latest compatible completed conversation from this step in this parent run. "
                + "Each invocation starts a new workflow. Explicit Resume refuses when reuse is unavailable.")
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
        }
    }

}
