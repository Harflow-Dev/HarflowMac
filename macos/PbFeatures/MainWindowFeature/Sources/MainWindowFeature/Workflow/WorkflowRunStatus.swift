import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowRunStatus

struct WorkflowRunStatus<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @State private var showsTasks = true

    var body: some View {
        if let run = viewModel.selectedRun {
            VStack(alignment: .leading, spacing: 12) {
                decision(run)
                if !run.tasks.isEmpty {
                    checklist(run)
                }
                if ["needs_attention", "paused"].contains(run.status) {
                    recovery(run)
                }
                if run.raw["kind"]?.stringValue == "builder", run.status == "completed" {
                    Button("Open generated draft") {
                        viewModel.openWorkflowEditor(run.name)
                    }.buttonStyle(QuietButtonStyle())
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

    private func checklist(_ run: WorkflowRunModel) -> some View {
        let completed = run.tasks.filter { $0["status"]?.stringValue == "completed" }.count
        return DisclosureGroup("Tasks · \(completed) of \(run.tasks.count) completed", isExpanded: $showsTasks) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(run.tasks.enumerated()), id: \.offset) { _, task in
                        HStack(alignment: .top, spacing: 8) {
                            let done = task["status"]?.stringValue == "completed"
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? Color.doneGreen : Color.secondaryText)
                                .accessibilityLabel(done ? "Completed by orchestrator" : "Pending")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task["title"]?.stringValue ?? task["id"]?.stringValue ?? "Task").font(.pb(.body))
                                if let reason = task["reason"]?.stringValue, !reason.isEmpty {
                                    Text(reason).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                                }
                            }
                        }
                    }
                }
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, 6)
            }.frame(maxHeight: 120)
        }.font(.pb(.secondary, weight: .medium))
    }

    private func recovery(_ run: WorkflowRunModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(run.reason.isEmpty ? "Scheduling is paused." : run.reason)
                .font(.pb(.secondary))
.foregroundStyle(Color.warningFG)
.textSelection(.enabled)
            HStack {
                TextField("Additional instructions", text: Binding(get: { viewModel.instructions }, set: { viewModel.instructions = $0 }))
                    .textFieldStyle(.roundedBorder)
                Stepper(
                    "Extra attempts: \(viewModel.additionalAttempts)",
                    value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
                    in: 0 ... 100
                )
                    .fixedSize()
                Button("Resume") { viewModel.control("resume") }.buttonStyle(QuietButtonStyle()).disabled(viewModel.isBusy)
            }.font(.pb(.body))
        }
    }
}

#if DEBUG
#Preview("Workflow decisions and checklist") {
    WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true)).frame(width: 900)
}
#endif
