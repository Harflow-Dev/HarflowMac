import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowAgentEditorPresentation

/// The candidate editor's pure presentation rules: vibe has no model or effort controls
/// (config-only, several layers removed from the command line), and a custom model entry that is
/// empty reverts to the backend's default.
enum WorkflowAgentEditorPresentation {
    static func showsModel(backend: String) -> Bool { backend != "vibe" }

    /// Cursor accepts a model id and has no separate effort flag.
    static func showsEffort(backend: String) -> Bool {
        showsModel(backend: backend) && !BackendStyle.effortLevels(backend).isEmpty
    }

    static func showsModelAndEffort(backend: String) -> Bool { showsModel(backend: backend) }

    /// Retains the supplied frequency order and the saved backend without duplicates.
    static func backendOptions(_ available: [String], current: String, preferred: String?) -> [String] {
        var seen = Set<String>()
        let first = preferred.flatMap { available.contains($0) ? $0 : nil }.map { [$0] } ?? []
        return (first + available + [current].filter { !$0.isEmpty }).filter { seen.insert($0).inserted }
    }

    /// A supported exact orchestrator model precedes Default for node menus only.
    static func modelOptions(_ available: [ModelChoiceModel], preferred: String?) -> [ModelChoiceModel] {
        var seen = Set<String>()
        let unique = available.filter { seen.insert($0.id).inserted }
        guard let preferred, !preferred.isEmpty, let match = unique.first(where: { $0.id == preferred }) else { return unique }
        return [match] + unique.filter { $0.id != preferred }
    }

    static func modelValue(_ text: String) -> JSONValue? {
        text.isEmpty ? nil : .string(text)
    }
}

// MARK: - WorkflowAgentEditorOperations

/// The ordered fallback list's pure mutations, shared by the editor and its tests: add, remove
/// and reorder keep the candidate's existing `fallbacks` ordering contract exactly.
enum WorkflowAgentEditorOperations {
    static func fallbacks(_ candidate: [String: JSONValue]) -> [[String: JSONValue]] {
        WorkflowJSON.objects(candidate["fallbacks"])
    }

    static func addingFallback(to candidate: [String: JSONValue], backendIDs: [String]) -> [String: JSONValue] {
        let fallback = WorkflowCandidateSettings.make(backend: backendIDs.first ?? "codex")
        var updated = candidate
        updated["fallbacks"] = .array((fallbacks(candidate) + [fallback]).map(JSONValue.object))
        return updated
    }

    static func removingFallback(at index: Int, in candidate: [String: JSONValue]) -> [String: JSONValue] {
        var values = fallbacks(candidate)
        guard values.indices.contains(index) else { return candidate }
        values.remove(at: index)
        var updated = candidate
        updated["fallbacks"] = .array(values.map(JSONValue.object))
        return updated
    }

    static func movingFallback(at index: Int, by delta: Int, in candidate: [String: JSONValue]) -> [String: JSONValue] {
        var values = fallbacks(candidate)
        guard values.indices.contains(index), values.indices.contains(index + delta) else { return candidate }
        values.swapAt(index, index + delta)
        var updated = candidate
        updated["fallbacks"] = .array(values.map(JSONValue.object))
        return updated
    }
}

// MARK: - WorkflowAgentEditor

/// The workflow's candidate editor uses the Monitor's backend dots, model combo and effort
/// vocabulary. Ordered fallbacks are the same candidate form, with explicit move controls.
/// Controls sit in grouped native rows (§5.5); no agent colour is ever used as a surface.
struct WorkflowAgentEditor: View {
    @Binding var candidate: [String: JSONValue]
    let backendIDs: [String]
    let modelChoices: [String: [ModelChoiceModel]]
    let loadModels: (String) -> Void
    var allowsFallbacks = true
    var callerApprovalBackends: Set<String> = []
    var preferredAgent: [String: JSONValue]?
    @State private var approvalNote: String?

    private var backend: String { candidate["backend"]?.stringValue ?? "" }
    private var allBackends: [String] {
        WorkflowAgentEditorPresentation.backendOptions(backendIDs, current: backend, preferred: preferredAgent?["backend"]?.stringValue)
    }

    private var displayedModels: [ModelChoiceModel] {
        WorkflowAgentEditorPresentation.modelOptions(modelChoices[backend] ?? [ModelChoiceModel(id: "", title: "Default")],
                                                     preferred: preferredAgent?["model"]?.stringValue)
    }

    private var approvalDescription: String {
        candidate["max_turns"] == nil || candidate["max_turns"] == .null
            ? "Exact action once. Requires non-native repository write or publish access; existing restrictions still apply."
            : "Caller approvals require an empty turn limit. Clear the explicit cap before starting."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            WorkflowFormGroup {
                WorkflowFormRow(label: "Harness") {
                    Picker("Harness", selection: binding("backend")) {
                        ForEach(allBackends, id: \.self) { id in BackendLabel(backend: id).tag(id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if WorkflowAgentEditorPresentation.showsModel(backend: backend) {
                    WorkflowFormDivider()
                    WorkflowFormRow(label: "Model") {
                        ModelCombo(
                            text: candidate["model"]?.stringValue ?? "",
                            choices: displayedModels
                        ) {
                            candidate["model"] = WorkflowAgentEditorPresentation.modelValue($0)
                        }
                        .frame(maxWidth: HfRadius.Metrics.workflowInspectorMinimumWidth)
                    }
                    .frame(minHeight: HfRadius.Metrics.formRowHeight)
                    if WorkflowAgentEditorPresentation.showsEffort(backend: backend) {
                        WorkflowFormDivider()
                        WorkflowFormRow(label: "Effort") {
                            Picker("Effort", selection: binding("reasoning_effort")) {
                                Text("Default").tag("")
                                ForEach(BackendStyle.effortLevels(backend), id: \.self) { Text($0.capitalized).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }
                if BackendStyle.supportsTurnLimit(backend) {
                    WorkflowFormDivider()
                    WorkflowFormRow(label: "Turn limit") {
                        TextField("Turn limit", text: Binding(get: {
                            WorkflowCandidateSettings.turnLimitText(candidate)
                        }, set: { value in
                            candidate["max_turns"] = value.isEmpty ? nil : Int(value).map { .number(Double($0)) } ?? .string(value)
                        }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: HfRadius.Metrics.workflowFieldValueWidth)
                            .accessibilityLabel("Turn limit")
                    }
                }
            }
            Toggle("Caller approvals: ask before each eligible action", isOn: Binding(
                get: { candidate["caller_approvals"]?.boolValue ?? false },
                set: { candidate["caller_approvals"] = .bool($0) }
            ))
                .disabled(!callerApprovalBackends.contains(backend))
            if let approvalNote { Text(approvalNote).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
            if candidate["caller_approvals"]?.boolValue == true {
                Text(approvalDescription)
                    .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
            } else if !callerApprovalBackends.contains(backend) {
                Text("Caller approvals are unsupported or unmeasured for this agent.").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
            if allowsFallbacks {
                fallbacks
            }
        }
        .font(.hf(.body))
        .onAppear { loadModels(backend) }
        .onChange(of: backend) { _, newValue in
            loadModels(newValue)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { candidate[key]?.stringValue ?? "" }, set: {
            if key == "backend" {
                let wasEnabled = candidate["caller_approvals"]?.boolValue == true
                candidate = WorkflowCandidateSettings.replacingBackend(in: candidate, with: $0, supportsCallerApprovals: callerApprovalBackends.contains($0))
                if wasEnabled, candidate["caller_approvals"]?.boolValue != true {
                    approvalNote = "Caller approvals were cleared because the selected agent does not support them."
                }
                return
            }
            candidate[key] = $0.isEmpty ? nil : .string($0)
        })
    }

    private var fallbackValues: [[String: JSONValue]] { WorkflowAgentEditorOperations.fallbacks(candidate) }

    private var fallbacks: some View {
        DisclosureGroup("Fallback harnesses (\(fallbackValues.count))") {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                ForEach(Array(fallbackValues.enumerated()), id: \.offset) { index, value in
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                        HStack {
                            Text("Fallback \(index + 1)").font(.hf(.secondary, weight: .semibold))
                            Spacer()
                            Button { moveFallback(index, by: -1) } label: { Image(systemName: "arrow.up") }
.disabled(index == 0)
                                .accessibilityLabel("Move fallback \(index + 1) up")
                            Button { moveFallback(index, by: 1) } label: { Image(systemName: "arrow.down") }
.disabled(index + 1 == fallbackValues.count)
                                .accessibilityLabel("Move fallback \(index + 1) down")
                            Button(role: .destructive) { removeFallback(index) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove fallback \(index + 1)")
                        }
                        .buttonStyle(.borderless)
                        WorkflowAgentEditor(
                            candidate: Binding(get: { fallbackValues.indices.contains(index) ? fallbackValues[index] : value }, set: { newValue in
                            var values = fallbackValues
                            guard values.indices.contains(index) else {
                                return
                            }
                            values[index] = newValue
                            candidate["fallbacks"] = .array(values.map(JSONValue.object))
                        }),
                            backendIDs: backendIDs,
                            modelChoices: modelChoices,
                            loadModels: loadModels,
                            allowsFallbacks: false,
                            callerApprovalBackends: callerApprovalBackends
                        )
                    }
                    .padding(HfRadius.Metrics.spacing10)
                    .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
                }
                Button("Add fallback", systemImage: "plus") {
                    candidate = WorkflowAgentEditorOperations.addingFallback(to: candidate, backendIDs: backendIDs)
                }
                .buttonStyle(QuietButtonStyle())
                Text("Tried in order for confirmed quota, model or availability failures.")
                    .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
            }
            .padding(.top, HfRadius.Metrics.spacing8)
        }
    }

    private func removeFallback(_ index: Int) {
        candidate = WorkflowAgentEditorOperations.removingFallback(at: index, in: candidate)
    }

    private func moveFallback(_ index: Int, by delta: Int) {
        candidate = WorkflowAgentEditorOperations.movingFallback(at: index, by: delta, in: candidate)
    }
}

#if DEBUG
private struct WorkflowAgentEditorPreview: View {
    var body: some View {
        WorkflowAgentEditor(
            candidate: .constant(["backend": .string("codex"), "fallbacks": .array([.object(["backend": .string("claude")])])]),
            backendIDs: ["codex", "claude", "vibe"],
            modelChoices: [:],
            loadModels: { _ in }
        )
        .padding()
        .frame(width: HfRadius.Metrics.formPreviewWidth)
    }
}

#Preview("Workflow agent editor - light") { WorkflowAgentEditorPreview().preferredColorScheme(.light) }
#Preview("Workflow agent editor - dark") { WorkflowAgentEditorPreview().preferredColorScheme(.dark) }
#Preview("Workflow agent editor - vibe") {
    WorkflowAgentEditor(
        candidate: .constant(["backend": .string("vibe")]),
        backendIDs: ["codex", "claude", "vibe"],
        modelChoices: [:],
        loadModels: { _ in }
    )
    .padding()
    .frame(width: HfRadius.Metrics.formPreviewWidth)
    .preferredColorScheme(.light)
}
#endif
