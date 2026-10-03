import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowRunStatus

struct WorkflowRunStatus<VM: WorkflowViewModel>: View {
    var viewModel: VM

    var body: some View {
        if let run = viewModel.selectedRun {
            VStack(alignment: .leading, spacing: 12) {
                decision(run)
                if let request = run.raw["prompt"]?.stringValue, !request.isEmpty, !run.isBuilder {
                    DisclosureGroup("Request") {
                        Text(request).font(.pb(.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.pb(.secondary))
                }
                if run.allowsMonitorControl, ["needs_attention", "paused", "needs_input"].contains(run.status) || (run.isDelegation && run.status == "failed") {
                    recovery(run)
                }
                if run.raw["kind"]?.stringValue == "builder", run.status == "completed" {
                    if run.isBuilderProposal {
                        Button("Apply proposal") { viewModel.applyAgentProposal() }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Open generated draft") { viewModel.openWorkflowEditor(run.name) }.buttonStyle(QuietButtonStyle())
                    }
                }
                if viewModel.canReturnToCanvas {
                    Button("Return to canvas") { viewModel.returnToCanvas() }.buttonStyle(QuietButtonStyle())
                }
                if viewModel.selectedActivationID != nil {
                    Button("Show latest steps") { viewModel.selectActivation(nil) }.buttonStyle(QuietButtonStyle())
                }
            }
.padding(.horizontal, 16)
.padding(.vertical, 10)
        }
    }

    private func decision(_ run: WorkflowRunModel) -> some View {
        let last = WorkflowJSON.objects(run.raw["decisions"]).last
        let deciding = run.activations.contains { $0["role"]?.stringValue == "orchestrator" && $0["status"]?.stringValue == "running" }
        return HStack(spacing: 8) {
            if deciding {
                RunningSpinner()
            } else {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.secondaryText)
            }
            Text(deciding ? "Orchestrator is choosing the next step…" : (last?["reason"]?.stringValue ?? "Waiting for the first step"))
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
.textSelection(.enabled)
            Spacer()
        }
    }

    private func recovery(_ run: WorkflowRunModel) -> some View {
        let missingAnswer = run.requiresAnswer && viewModel.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text(run.question.isEmpty ? "Scheduling is paused." : run.question)
                .font(.pb(.secondary))
.foregroundStyle(Color.warningFG)
.textSelection(.enabled)
            if run.isSettling { Text("Waiting for running branches to finish…").font(.pb(.secondary)).foregroundStyle(Color.secondaryText) }
            HStack {
                TextField("Additional instructions", text: Binding(get: { viewModel.instructions }, set: { viewModel.instructions = $0 }))
                    .textFieldStyle(.roundedBorder)
                Stepper(
                    "Extra attempts: \(viewModel.additionalAttempts)",
                    value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
                    in: 0 ... 100
                )
                    .fixedSize()
                if run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false {
                    Button("Continue with one more retry") { viewModel.continueWithOneMoreRetry() }
                        .buttonStyle(QuietButtonStyle())
.disabled(viewModel.isBusy || run.isSettling || missingAnswer)
                }
                Button(run.status == "failed" ? "Recover" : "Resume") { viewModel.control(run.status == "failed" ? "recover" : "resume") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
            }.font(.pb(.body))
        }
    }
}

#if DEBUG
#Preview("Workflow decisions and checklist") {
    WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true)).frame(width: 900)
}
#endif
