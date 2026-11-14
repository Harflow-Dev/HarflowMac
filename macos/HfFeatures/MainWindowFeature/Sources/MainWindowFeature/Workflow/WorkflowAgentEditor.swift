import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowAgentEditorPresentation

/// The candidate editor's pure presentation rules. Rows follow the engine-reported controls: a row
/// is hidden only when its control is `unsupported`, and a saved value is never hidden while it is
/// still sent. A custom model entry that is empty reverts to the backend's default.
enum WorkflowAgentEditorPresentation {
    /// Shown beside a row whose control the app cannot check right now.
    static let unknownCaption = "Can't be checked right now"
    /// Shown beside a row that is visible only because a value is saved for an unsupported control.
    static let unavailableCaption = "Unavailable for this harness"

    static func showsUnavailableCaption(_ state: ControlState) -> Bool { state == .unsupported }

    /// The backend picker's mutation: clears model and effort, and keeps `max_turns` only when the
    /// NEW harness's turn cap is supported in the catalog.
    static func replacingBackend(
        in candidate: [String: JSONValue], with backend: String,
        callerApprovalBackends: Set<String>, backendControls: [String: BackendControls]
    ) -> [String: JSONValue] {
        WorkflowCandidateSettings.replacingBackend(
            in: candidate, with: backend, supportsCallerApprovals: callerApprovalBackends.contains(backend),
            supportsTurnCap: backendControls[backend]?.turnCap == .supported
        )
    }

    /// One entry of the Effort menu.
    struct EffortOption: Equatable {
        let value: String
        let title: String
    }

    static func hasSaved(_ candidate: [String: JSONValue], _ key: String) -> Bool {
        guard let value = candidate[key], value != .null else { return false }
        return value.stringValue?.isEmpty != true
    }

    static func showsModel(_ controls: BackendControls, candidate: [String: JSONValue]) -> Bool {
        controls.model != .unsupported || hasSaved(candidate, "model")
    }

    static func showsEffort(_ controls: BackendControls, candidate: [String: JSONValue]) -> Bool {
        controls.effort != .unsupported || hasSaved(candidate, "reasoning_effort")
    }

    static func showsTurnLimit(_ controls: BackendControls, candidate: [String: JSONValue]) -> Bool {
        controls.turnCap != .unsupported || hasSaved(candidate, "max_turns")
    }

    /// The harness controls narrowed by the node's own saved model. Only a saved model that exactly matches
    /// one of this harness's suggestions (surrounding whitespace ignored) contributes its effort levels;
    /// an empty or unmatched model, or the synthetic Default row, leaves the harness controls as they are.
    static func effectiveControls(_ controls: BackendControls, candidate: [String: JSONValue],
                                  choices: [ModelChoiceModel]) -> BackendControls {
        let model = (candidate["model"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let levels = model.isEmpty ? nil : choices.first { $0.id == model }?.effortLevels
        return BackendControls.effectiveControls(harness: controls, modelEffortLevels: levels)
    }

    /// Default, then the engine's levels in its order (never invented). A saved value outside them
    /// stays selectable and says it is unavailable for this harness.
    static func effortOptions(_ controls: BackendControls, saved: String) -> [EffortOption] {
        var options = [EffortOption(value: "", title: "Default")]
        var known: [String] = []
        if case .levels(let levels) = controls.effort { known = levels }
        options += known.map { EffortOption(value: $0, title: $0.capitalized) }
        if !saved.isEmpty, !known.contains(saved) {
            let title = controls.effort == .unknown ? saved.capitalized : "\(saved) — unavailable for this harness"
            options.append(EffortOption(value: saved, title: title))
        }
        return options
    }

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
    var backendControls: [String: BackendControls] = [:]
    var preferredAgent: [String: JSONValue]?
    @State private var approvalNote: String?

    private var backend: String { candidate["backend"]?.stringValue ?? "" }
    private var controls: BackendControls { backendControls[backend] ?? .unavailable }
    /// The harness controls as narrowed by this node's saved model; drives only the Effort row.
    private var effortControls: BackendControls {
        WorkflowAgentEditorPresentation.effectiveControls(controls, candidate: candidate, choices: modelChoices[backend] ?? [])
    }

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
                if WorkflowAgentEditorPresentation.showsModel(controls, candidate: candidate) {
                    WorkflowFormDivider()
                    WorkflowFormRow(label: "Model") {
                        VStack(alignment: .trailing, spacing: HfRadius.Metrics.spacing4) {
                            ModelCombo(
                                text: candidate["model"]?.stringValue ?? "",
                                choices: displayedModels
                            ) {
                                candidate["model"] = WorkflowAgentEditorPresentation.modelValue($0)
                            }
                            .frame(maxWidth: HfRadius.Metrics.workflowInspectorMinimumWidth)
                            if WorkflowAgentEditorPresentation.showsUnavailableCaption(controls.model) {
                                Text(WorkflowAgentEditorPresentation.unavailableCaption).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                            }
                            caption(for: controls.model)
                        }
                    }
                    .frame(minHeight: HfRadius.Metrics.formRowHeight)
                }
                if WorkflowAgentEditorPresentation.showsEffort(effortControls, candidate: candidate) {
                    WorkflowFormDivider()
                    WorkflowFormRow(label: "Effort") {
                        VStack(alignment: .trailing, spacing: HfRadius.Metrics.spacing4) {
                            Picker("Effort", selection: binding("reasoning_effort")) {
                                ForEach(WorkflowAgentEditorPresentation.effortOptions(
                                    effortControls, saved: candidate["reasoning_effort"]?.stringValue ?? ""
                                ), id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            caption(for: effortControls.effort == .unknown ? .unknown : .supported)
                        }
                    }
                }
                if WorkflowAgentEditorPresentation.showsTurnLimit(controls, candidate: candidate) {
                    WorkflowFormDivider()
                    WorkflowFormRow(label: "Turn limit") {
                        VStack(alignment: .trailing, spacing: HfRadius.Metrics.spacing4) {
                            TextField("Turn limit", text: Binding(get: {
                                WorkflowCandidateSettings.turnLimitText(candidate, turnCap: controls.turnCap)
                            }, set: { value in
                                candidate["max_turns"] = value.isEmpty ? nil : Int(value).map { .number(Double($0)) } ?? .string(value)
                            }))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: HfRadius.Metrics.workflowFieldValueWidth)
                                .accessibilityLabel("Turn limit")
                            if controls.turnCap == .unsupported {
                                Text(WorkflowAgentEditorPresentation.unavailableCaption).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                            }
                            caption(for: controls.turnCap)
                        }
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
        .onAppear { loadSuggestions(for: backend) }
        .onChange(of: backend) { _, newValue in loadSuggestions(for: newValue) }
        .onChange(of: controls.model) { _, _ in loadSuggestions(for: backend) }
    }

    /// Suggestions load only where the engine says the harness takes a model.
    private func loadSuggestions(for backend: String) {
        guard (backendControls[backend] ?? .unavailable).model == .supported else { return }
        loadModels(backend)
    }

    @ViewBuilder
    private func caption(for state: ControlState) -> some View {
        if state == .unknown {
            Text(WorkflowAgentEditorPresentation.unknownCaption).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { candidate[key]?.stringValue ?? "" }, set: {
            if key == "backend" {
                let wasEnabled = candidate["caller_approvals"]?.boolValue == true
                candidate = WorkflowAgentEditorPresentation.replacingBackend(
                    in: candidate, with: $0, callerApprovalBackends: callerApprovalBackends, backendControls: backendControls
                )
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
                            callerApprovalBackends: callerApprovalBackends,
                            backendControls: backendControls
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
private let previewControls: [String: BackendControls] = [
    "codex": BackendControls(model: .supported, effort: .levels(["low", "medium", "high", "xhigh"]), turnCap: .unsupported),
    "claude": .previewClaudeLike,
    "vibe": .previewVibeLike
]

private struct WorkflowAgentEditorPreview: View {
    var body: some View {
        WorkflowAgentEditor(
            candidate: .constant(["backend": .string("codex"), "fallbacks": .array([.object(["backend": .string("claude")])])]),
            backendIDs: ["codex", "claude", "vibe"],
            modelChoices: [:],
            loadModels: { _ in },
            backendControls: previewControls
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
        loadModels: { _ in },
        backendControls: previewControls
    )
    .padding()
    .frame(width: HfRadius.Metrics.formPreviewWidth)
    .preferredColorScheme(.light)
}
#endif
