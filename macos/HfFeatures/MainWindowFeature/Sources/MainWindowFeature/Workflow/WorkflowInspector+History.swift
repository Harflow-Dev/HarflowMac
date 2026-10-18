import HfUI
import MonitorCore
import SwiftUI

// MARK: - Workflow inspector execution history

extension WorkflowInspector {
    private func childSessionDetails(_ activation: [String: JSONValue]) -> some View {
        let details = WorkflowChildSessionDetails(invocation: activation["invocation"]?.objectValue ?? [:])
        return ForEach(Array(details.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.hf(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func invocationSessionDetails(_ activation: [String: JSONValue]) -> some View {
        if let retryOf = activation["retry_of_execution_id"]?.stringValue {
            Text("Retry of execution " + retryOf).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
        executionSessionDetails(activation)
        childSessionDetails(activation)
    }

    @ViewBuilder
    private func selectedArtifacts(_ node: WorkflowNodeModel) -> some View {
    if let run = viewModel.selectedRun,
       let activation = run.activations.last(where: { activation in
           activation["node_id"]?.stringValue == node.id
               && (viewModel.selectedActivationID.map { activation["id"]?.stringValue == $0 }
                   ?? (activation["role"]?.stringValue == "node"))
       }), let executionID = activation["id"]?.stringValue {
        WorkflowArtifactsView(model: viewModel.artifacts, load: viewModel.loadArtifacts)
            .task(id: run.id + ":" + executionID) { viewModel.prepareArtifacts(runID: run.id, executionID: executionID) }
    }
    }

    private func attemptLabel(_ activation: [String: JSONValue], index: Int) -> String {
        let label = activation["role"]?.stringValue == "orchestrator" ? "Decision" : "Attempt"
        let attempt = activation["attempt_in_visit"]?.intValue ?? index + 1
        return "\(label) \(attempt) · \(activation["status"]?.stringValue ?? "")"
    }

    func nodeHistory(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            SectionLabel(text: node.name)
            if node.type == "agent" {
                Text(node.isOptional ? "Optional step" : "Required step")
                    .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            Text(node.instructions).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            selectedArtifacts(node)
            Button("Show latest steps") { viewModel.selectActivation(nil) }.buttonStyle(QuietButtonStyle())
            ForEach(Array((viewModel.selectedRun?.activations.filter {
                $0["node_id"]?.stringValue == node.id
            } ?? []).enumerated()), id: \.offset) { index, activation in
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    Text(attemptLabel(activation, index: index))
                        .font(.hf(.secondary, weight: .semibold))
                    if let error = activation["result_error"]?.stringValue {
                        Text(error).font(.hf(.secondary)).foregroundStyle(Color.warningFG).textSelection(.enabled)
                    }
                    invocationSessionDetails(activation)
                    if let assignment = activation["assignment_prompt"]?.stringValue {
                        Text("Assignment").font(.hf(.secondary, weight: .semibold))
                        Text(assignment).font(.hf(.secondary)).textSelection(.enabled)
                    }
                    ForEach(Array(WorkflowJSON.objects(activation["questions"]).enumerated()), id: \.offset) { _, question in
                        Text("Question: " + (question["question"]?.stringValue ?? "")).font(.hf(.secondary)).textSelection(.enabled)
                        if let context = question["context"]?.stringValue { Text(context).font(.hf(.secondary)).textSelection(.enabled) }
                        if let answer = question["answer"]?.stringValue {
                            Text("Answer: " + answer).font(.hf(.secondary)).textSelection(.enabled)
                        }
                    }
                    if let result = activation["node_result"], let description = WorkflowNodePresentation.summary(result.rendered()) {
                        Text("Result").font(.hf(.secondary, weight: .semibold))
                        Text(description).font(.hf(.secondary)).textSelection(.enabled)
                    }
                    if activation["role"]?.stringValue == "node", let id = activation["id"]?.stringValue {
                        Button("Show activity") { viewModel.selectActivation(id) }.buttonStyle(QuietButtonStyle())
                    }
                    ForEach(Array(WorkflowJSON.objects(activation["tasks"]).enumerated()), id: \.offset) { _, task in
                        let attempt = WorkflowExecutionAttempts.fallbackIndices(activation)[task["task_id"]?.stringValue ?? ""] ?? 0
                        HStack(alignment: .top, spacing: HfRadius.Metrics.spacing6) {
                            BackendDot(backend: task["candidate"]?["backend"]?.stringValue ?? "")
                            VStack(alignment: .leading, spacing: HfRadius.Metrics.rowLineSpacing) {
                                Text("\(attempt == 0 ? "Primary" : "Fallback \(attempt)"): \(task["candidate"]?["backend"]?.stringValue ?? "agent")")
                                Text(task["status"]?.stringValue ?? "").foregroundStyle(Color.secondaryText)
                                if let reason = task["reason"]?.stringValue {
                                    Text(reason).foregroundStyle(Color.secondaryText)
                                }
                                ForEach(Array(WorkflowContextDelivery(task: task).lines.enumerated()), id: \.offset) { _, line in
                                    Text(line).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                                }
                            }.font(.hf(.caption))
                        }
                    }
                }
.padding(HfRadius.Metrics.spacing10)
.background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
            }
        }
    }

    @ViewBuilder
    func executionSessionDetails(_ activation: [String: JSONValue]) -> some View {
        let execution = WorkflowExecutionPresentation(raw: activation)
        Text(execution.label).font(.hf(.caption, weight: .semibold))
        if let reason = execution.fallbackReason {
            Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
        if execution.isSubagent {
            if let owner = execution.ownerTaskID {
                Button("Open owning orchestrator") { viewModel.openOwnerTask(owner) }.buttonStyle(QuietButtonStyle())
            } else {
                Text("Owning orchestrator history unavailable").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
            if execution.activityLimited {
                Text("Activity limited").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        if let mode = activation["execution_session_mode"]?.stringValue {
            Text("Session: " + mode.replacingOccurrences(of: "_", with: " "))
                .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
        }
        if let reason = activation["session_reason"]?.stringValue {
            Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
        }
    }

}
