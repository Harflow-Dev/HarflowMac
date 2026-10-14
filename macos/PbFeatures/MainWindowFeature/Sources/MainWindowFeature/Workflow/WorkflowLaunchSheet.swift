import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowLaunchSheet

struct WorkflowLaunchSheet<VM: WorkflowViewModel>: View {
    var viewModel: VM
    let isGenerating: Bool

    private var sheetTitle: String {
        isGenerating ? (viewModel.isRefining ? "Edit workflow with agent" : "Generate a workflow") : "Run workflow"
    }

    private var sheetDescription: String {
        guard isGenerating else { return "Agents follow the graph. Polybridge tracks execution and enforces limits." }
        return viewModel.isRefining
            ? "An agent proposes changes to your current canvas. Review and apply them, then Save when ready."
            : "An agent creates a draft. Polybridge validates and stores it for you to edit."
    }

    private var canSubmit: Bool {
        (isGenerating || viewModel.canStartWithPreview) && WorkflowBuilderLayout.canSubmit(isGenerating: isGenerating, isBusy: viewModel.isBusy,
                                        name: viewModel.name, repo: viewModel.repo, prompt: viewModel.prompt)
    }

    var body: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            ScrollView {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing24) {
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                        Text(sheetTitle).font(.pb(.headline, weight: .semibold))
                        Text(sheetDescription)
                            .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                    }
                    if isGenerating {
                        TextField("Workflow name", text: Binding(get: { viewModel.name }, set: { viewModel.name = $0 })).textFieldStyle(.roundedBorder)
                    } else {
                        Text(viewModel.loadedName).font(.pb(.body, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                        SectionLabel(text: isGenerating ? (viewModel.isRefining ? "Describe the changes" : "Describe the workflow") : "Task")
                        TextEditor(text: Binding(get: { viewModel.prompt }, set: { viewModel.prompt = $0 }))
.font(.pb(.body))
                            // Bounded scope (§6.3): the prompt editor's own scroll view, if one
                            // exists; a quiet no-op otherwise.
                            .scrollChromeScope()
.frame(minHeight: PbRadius.Metrics.sidebarSearchMinimumWidth)
                            .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                            .accessibilityLabel(isGenerating ? "Workflow request" : "Workflow task")
                    }
                    if !isGenerating {
                        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                            SectionLabel(text: "Goal (optional)")
                            TextEditor(text: Binding(get: { viewModel.goal }, set: { viewModel.goal = $0 }))
                                .font(.pb(.body))
.scrollChromeScope()
                                .frame(minHeight: PbRadius.Metrics.sidebarSearchMinimumWidth)
                                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                                .accessibilityLabel("Workflow goal")
                            Text("Describe the result and the evidence needed to verify it.")
                                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                        }
                    }
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                        SectionLabel(text: isGenerating ? "Repository (optional)" : "Repository")
                        HStack {
                            TextField(isGenerating ? "Optional repository for context" : "/path/to/repository",
                                      text: Binding(get: { viewModel.repo }, set: { viewModel.repo = $0 }))
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
                        if let preview = viewModel.launchPreview {
                            WorkflowPermissionsView(model: preview.permissions)
                        } else if let message = viewModel.launchPreviewMessage {
                            Text(message).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                        }
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
                }
.padding(PbRadius.Metrics.spacing28)
                // The document probe (§6.3): inside the sheet's own document, so it can only ever
                // target this outer scroll view — never the prompt editor's.
                .background(ScrollChrome())
            }
            if let error = viewModel.errorText {
                Text(error)
.font(.pb(.secondary))
.foregroundStyle(Color.failedRed)
.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
.padding(.horizontal, PbRadius.Metrics.spacing28)
.padding(.bottom, PbRadius.Metrics.spacing12)
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
                Button(isGenerating ? (viewModel.isRefining ? "Propose changes" : "Generate") : "Run") {
                    if isGenerating {
                        viewModel.generate()
                    } else {
                        viewModel.start()
                    }
                }
.buttonStyle(.borderedProminent)
.disabled(!canSubmit)
            }.padding(PbRadius.Metrics.spacing20)
        }.frame(width: PbRadius.Metrics.workflowLaunchSheetWidth, height: PbRadius.Metrics.workflowLaunchSheetHeight)
    }

}

#if DEBUG
#Preview("Workflow launch") { WorkflowLaunchSheet(viewModel: WorkflowPreview.make(), isGenerating: false) }
#Preview("Workflow launch - orchestrator override, dark") {
    let vm = WorkflowPreview.make()
    vm.overrideOrchestrator = true
    return WorkflowLaunchSheet(viewModel: vm, isGenerating: false).preferredColorScheme(.dark)
}

#Preview("Workflow generation - light") {
    WorkflowLaunchSheet(viewModel: WorkflowPreview.make(), isGenerating: true).preferredColorScheme(.light)
}

#Preview("Workflow generation - fixed 580-point sheet") {
    WorkflowLaunchSheet(viewModel: WorkflowPreview.make(), isGenerating: true)
}
#endif
