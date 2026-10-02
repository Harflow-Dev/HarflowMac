import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowAgentEditor

/// The workflow's candidate editor uses the Monitor's backend dots, model combo and effort
/// vocabulary. Ordered fallbacks are the same candidate form, with explicit move controls.
struct WorkflowAgentEditor: View {
    @Binding var candidate: [String: JSONValue]
    let backendIDs: [String]
    let modelChoices: [String: [ModelChoiceModel]]
    let loadModels: (String) -> Void
    var allowsFallbacks = true

    private var backend: String { candidate["backend"]?.stringValue ?? "" }
    private var allBackends: [String] { Array(Set(backendIDs + [backend].filter { !$0.isEmpty })).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Agent", selection: binding("backend")) {
                ForEach(allBackends, id: \.self) { id in BackendLabel(backend: id).tag(id) }
            }
            if backend != "vibe" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                    ModelCombo(
                        text: candidate["model"]?.stringValue ?? "",
                        choices: modelChoices[backend] ?? [ModelChoiceModel(id: "", title: "Default")]
                    ) {
                        candidate["model"] = $0.isEmpty ? nil : .string($0)
                    }
                }
                Picker("Effort", selection: binding("reasoning_effort")) {
                    Text("Default").tag("")
                    ForEach(BackendStyle.effortLevels(backend), id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            if BackendStyle.supportsTurnLimit(backend) {
                TextField("Turn limit", text: Binding(get: {
                WorkflowCandidateSettings.turnLimitText(candidate)
            }, set: { value in
                candidate["max_turns"] = value.isEmpty ? nil : Int(value).map { .number(Double($0)) } ?? .string(value)
            }))
                .textFieldStyle(.roundedBorder)
            }
            if allowsFallbacks {
                fallbacks
            }
        }
        .font(.pb(.body))
        .onAppear { loadModels(backend) }
        .onChange(of: backend) { _, newValue in
            loadModels(newValue)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { candidate[key]?.stringValue ?? "" }, set: {
            if key == "backend" {
                candidate = WorkflowCandidateSettings.replacingBackend(in: candidate, with: $0)
                return
            }
            candidate[key] = $0.isEmpty ? nil : .string($0)
        })
    }

    private var fallbackValues: [[String: JSONValue]] { WorkflowJSON.objects(candidate["fallbacks"]) }

    private var fallbacks: some View {
        DisclosureGroup("Fallback agents (\(fallbackValues.count))") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(fallbackValues.enumerated()), id: \.offset) { index, value in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Fallback \(index + 1)").font(.pb(.secondary, weight: .semibold))
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
                            allowsFallbacks: false
                        )
                    }
                    .padding(10)
                    .background(Color.composerFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
                }
                Button("Add fallback", systemImage: "plus") {
                    let fallback = WorkflowCandidateSettings.make(backend: backendIDs.first ?? "codex")
                    candidate["fallbacks"] = .array((fallbackValues + [fallback]).map(JSONValue.object))
                }
                .buttonStyle(QuietButtonStyle())
                Text("Tried in order for confirmed quota, model or availability failures.")
                    .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            }
            .padding(.top, 8)
        }
    }

    private func removeFallback(_ index: Int) {
        var values = fallbackValues
        values.remove(at: index)
        candidate["fallbacks"] = .array(values.map(JSONValue.object))
    }

    private func moveFallback(_ index: Int, by delta: Int) {
        var values = fallbackValues
        guard values.indices.contains(index + delta) else {
            return
        }
        values.swapAt(index, index + delta)
        candidate["fallbacks"] = .array(values.map(JSONValue.object))
    }
}

#if DEBUG
#Preview {
    WorkflowAgentEditor(
        candidate: .constant(["backend": .string("codex"), "fallbacks": .array([.object(["backend": .string("claude")])])]),
        backendIDs: ["codex", "claude", "vibe"],
        modelChoices: [:],
        loadModels: { _ in }
    )
        .padding()
.frame(width: 300)
}
#endif
