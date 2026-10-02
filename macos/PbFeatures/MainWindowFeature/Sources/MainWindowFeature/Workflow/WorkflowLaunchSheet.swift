import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowLaunchSheet

struct WorkflowLaunchSheet<VM: WorkflowViewModel>: View {
    var viewModel: VM
    let isGenerating: Bool

    private var canSubmit: Bool {
        !viewModel.isBusy && !viewModel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.repo.isEmpty && !viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isGenerating ? "Generate a workflow" : "Run workflow").font(.pb(.headline, weight: .semibold))
                        Text(isGenerating ? "An agent creates a draft. Polybridge validates and stores it for you to edit." :
                            "Agents follow the graph. Polybridge tracks execution and enforces limits.")
                            .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                    }
                    if isGenerating {
                        TextField("Workflow name", text: Binding(get: { viewModel.name }, set: { viewModel.name = $0 })).textFieldStyle(.roundedBorder)
                    } else {
                        Text(viewModel.loadedName).font(.pb(.body, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: isGenerating ? "Describe the workflow" : "Task")
                        TextEditor(text: Binding(get: { viewModel.prompt }, set: { viewModel.prompt = $0 }))
.font(.pb(.body))
.frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                            .accessibilityLabel(isGenerating ? "Workflow request" : "Workflow task")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Repository")
                        HStack {
                            TextField("/path/to/repository", text: Binding(get: { viewModel.repo }, set: { viewModel.repo = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { viewModel.chooseRepo() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    if isGenerating {
                        SectionLabel(text: "Builder agent")
                        WorkflowAgentEditor(
                            candidate: Binding(get: { viewModel.generationAgent }, set: { viewModel.generationAgent = $0 }),
                            backendIDs: viewModel.backendIDs,
                            modelChoices: viewModel.modelChoices,
                            loadModels: viewModel.loadModels
                        )
                    } else {
                        accessOptions
                        Toggle(
                            "Override orchestrator agent",
                            isOn: Binding(get: { viewModel.overrideOrchestrator }, set: { viewModel.overrideOrchestrator = $0 })
                        )
                        if viewModel.overrideOrchestrator {
                            WorkflowAgentEditor(
                                candidate: Binding(get: { viewModel.launchAgent }, set: { viewModel.launchAgent = $0 }),
                                backendIDs: viewModel.backendIDs,
                                modelChoices: viewModel.modelChoices,
                                loadModels: viewModel.loadModels,
                                allowsFallbacks: false
                            )
                            Text("Saved fallback agents remain in effect.").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                        }
                    }
                }.padding(28)
            }
            if let error = viewModel.errorText {
                Text(error)
.font(.pb(.secondary))
.foregroundStyle(Color.failedRed)
.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
.padding(.horizontal, 28)
.padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Cancel") {
                    viewModel.showsRunSheet = false
                    viewModel.showsGenerateSheet = false
                }.buttonStyle(QuietButtonStyle())
                Spacer()
                if viewModel.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button(isGenerating ? "Generate" : "Run") {
                    if isGenerating {
                        viewModel.generate()
                    } else {
                        viewModel.start()
                    }
                }
.buttonStyle(.borderedProminent)
.disabled(!canSubmit)
            }.padding(20)
        }.frame(width: 580, height: 650)
    }

    private var accessOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Run access limit")
            ForEach(WorkflowAccess.levels, id: \.self) { level in
                AccessOptionRow(model: AccessOptionModel(
                    id: level,
                    title: WorkflowAccess.title(level),
                    detail: accessDetail(level),
                    isSelected: viewModel.freedom == level,
                    isWarning: ["publish", "unrestricted"].contains(level)
                )) {
                    viewModel.freedom = level
                }
            }
        }
    }

    private func accessDetail(_ level: String) -> String {
        switch level {
        case "read_only": "Limit every step to reading. Workflows with implementation steps require write access."
        case "write_in_repo": "Allow repository edits; each step keeps its configured access limit."
        case "publish": "Allow publication where a step permits it; each step keeps its configured access limit."
        default: "Allow unrestricted execution where a step permits it; each step keeps its configured access limit."
        }
    }

}

#if DEBUG
#Preview("Workflow launch") { WorkflowLaunchSheet(viewModel: WorkflowPreview.make(), isGenerating: false) }
#endif
