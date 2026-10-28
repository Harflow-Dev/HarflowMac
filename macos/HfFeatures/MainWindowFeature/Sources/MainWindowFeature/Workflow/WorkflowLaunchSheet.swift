import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowLaunchSheet

struct WorkflowLaunchSheet<VM: WorkflowViewModel>: View {
    var viewModel: VM
    let isGenerating: Bool

    private var sheetTitle: String {
        isGenerating ? (viewModel.isRefining ? "Edit workflow with agent" : "Generate a workflow") : "Run workflow"
    }

    private var sheetDescription: String {
        guard isGenerating else { return "Agents follow the graph. Harflow tracks execution and enforces limits." }
        return viewModel.isRefining
            ? "An agent proposes changes to your current canvas. Review and apply them, then Save when ready."
            : "An agent creates a draft. Harflow validates and stores it for you to edit."
    }

    private var canSubmit: Bool {
        (isGenerating || viewModel.canStartWithPreview) && WorkflowBuilderLayout.canSubmit(isGenerating: isGenerating, isBusy: viewModel.isBusy,
                                        name: viewModel.name, repo: viewModel.repo, prompt: viewModel.prompt)
    }

    var body: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            ScrollView {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing24) {
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
                        Text(sheetTitle).font(.hf(.headline, weight: .semibold))
                        Text(sheetDescription)
                            .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                    }
                    if isGenerating {
                        TextField("Workflow name", text: Binding(get: { viewModel.name }, set: { viewModel.name = $0 })).textFieldStyle(.roundedBorder)
                    } else {
                        Text(viewModel.loadedName).font(.hf(.body, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                        SectionLabel(text: isGenerating ? (viewModel.isRefining ? "Describe the changes" : "Describe the workflow") : "Task")
                        TextEditor(text: Binding(get: { viewModel.prompt }, set: { viewModel.prompt = $0 }))
.font(.hf(.body))
                            // Bounded scope (§6.3): the prompt editor's own scroll view, if one
                            // exists; a quiet no-op otherwise.
                            .scrollChromeScope()
.frame(minHeight: HfRadius.Metrics.sidebarSearchMinimumWidth)
                            .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
                            .accessibilityLabel(isGenerating ? "Workflow request" : "Workflow task")
                    }
                    if !isGenerating {
                        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                            SectionLabel(text: "Goal (optional)")
                            TextEditor(text: Binding(get: { viewModel.goal }, set: { viewModel.goal = $0 }))
                                .font(.hf(.body))
.scrollChromeScope()
                                .frame(minHeight: HfRadius.Metrics.sidebarSearchMinimumWidth)
                                .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
                                .accessibilityLabel("Workflow goal")
                            Text("Describe the result and the evidence needed to verify it.")
                                .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                        }
                    }
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                        SectionLabel(text: isGenerating ? "Repository (optional)" : "Repository")
                        HStack {
                            TextField(isGenerating ? "Optional repository for context" : "/path/to/repository",
                                      text: Binding(get: { viewModel.repo }, set: { viewModel.repo = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { viewModel.chooseRepo() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    if isGenerating {
                        SectionLabel(text: "Builder harness")
                        WorkflowAgentEditor(
                            candidate: Binding(get: { viewModel.generationAgent }, set: { viewModel.generationAgent = $0 }),
                            backendIDs: viewModel.backendIDs,
                            modelChoices: viewModel.modelChoices,
                            loadModels: viewModel.loadModels, callerApprovalBackends: viewModel.callerApprovalBackends
                        )
                    } else {
                        if let preview = viewModel.launchPreview {
                            WorkflowPermissionsView(model: preview.permissions)
                        } else if let message = viewModel.launchPreviewMessage {
                            Text(message).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                        }
                        Toggle(
                            "Override orchestrator harness",
                            isOn: Binding(get: { viewModel.overrideOrchestrator }, set: { viewModel.overrideOrchestrator = $0 })
                        )
                        if viewModel.overrideOrchestrator {
                            WorkflowAgentEditor(
                                candidate: Binding(get: { viewModel.launchAgent }, set: { viewModel.launchAgent = $0 }),
                                backendIDs: viewModel.backendIDs,
                                modelChoices: viewModel.modelChoices,
                                loadModels: viewModel.loadModels,
                                allowsFallbacks: false, callerApprovalBackends: viewModel.callerApprovalBackends
                            )
                            Text("Saved fallback harnesses remain in effect.").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                        }
                        LazyVStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                            ForEach(viewModel.qualificationCards) { card in
                                HarnessQualificationCard(model: card.model, action: viewModel.didTapQualification)
                            }
                        }
                    }
                }
.padding(HfRadius.Metrics.spacing28)
                // The document probe (§6.3): inside the sheet's own document, so it can only ever
                // target this outer scroll view — never the prompt editor's.
                .background(ScrollChrome())
            }
            if let error = viewModel.errorText {
                Text(error)
.font(.hf(.secondary))
.foregroundStyle(Color.failedRed)
.textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
.padding(.horizontal, HfRadius.Metrics.spacing28)
.padding(.bottom, HfRadius.Metrics.spacing12)
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
            }.padding(HfRadius.Metrics.spacing20)
        }.frame(width: HfRadius.Metrics.workflowLaunchSheetWidth, height: HfRadius.Metrics.workflowLaunchSheetHeight)
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
