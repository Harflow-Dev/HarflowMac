import MonitorCore
import PbUI
import SwiftUI

// MARK: - Workflow inspector execution history

extension WorkflowInspector {
    private func childSessionDetails(_ activation: [String: JSONValue]) -> some View {
        let details = WorkflowChildSessionDetails(invocation: activation["invocation"]?.objectValue ?? [:])
        return ForEach(Array(details.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.pb(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func invocationSessionDetails(_ activation: [String: JSONValue]) -> some View {
        if let retryOf = activation["retry_of_execution_id"]?.stringValue {
            Text("Retry of execution " + retryOf).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
        }
        executionSessionDetails(activation)
        childSessionDetails(activation)
    }

    func nodeHistory(_ node: WorkflowNodeModel) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
            SectionLabel(text: node.name)
            if node.type == "agent" {
                Text(node.isOptional ? "Optional step" : "Required step")
                    .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            Text(node.instructions).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            Button("Show latest steps") { viewModel.selectActivation(nil) }.buttonStyle(QuietButtonStyle())
            ForEach(Array((viewModel.selectedRun?.activations.filter {
                $0["node_id"]?.stringValue == node.id
            } ?? []).enumerated()), id: \.offset) { index, activation in
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                    let label = activation["role"]?.stringValue == "orchestrator" ? "Decision" : "Attempt"
                    let attempt = activation["attempt_in_visit"]?.intValue ?? index + 1
                    Text("\(label) \(attempt) · \(activation["status"]?.stringValue ?? "")")
                        .font(.pb(.secondary, weight: .semibold))
                    if let error = activation["result_error"]?.stringValue {
                        Text(error).font(.pb(.secondary)).foregroundStyle(Color.warningFG).textSelection(.enabled)
                    }
                    invocationSessionDetails(activation)
                    if let assignment = activation["assignment_prompt"]?.stringValue {
                        Text("Assignment").font(.pb(.secondary, weight: .semibold))
                        Text(assignment).font(.pb(.secondary)).textSelection(.enabled)
                    }
                    ForEach(Array(WorkflowJSON.objects(activation["questions"]).enumerated()), id: \.offset) { _, question in
                        Text("Question: " + (question["question"]?.stringValue ?? "")).font(.pb(.secondary)).textSelection(.enabled)
                        if let context = question["context"]?.stringValue { Text(context).font(.pb(.secondary)).textSelection(.enabled) }
                        if let answer = question["answer"]?.stringValue {
                            Text("Answer: " + answer).font(.pb(.secondary)).textSelection(.enabled)
                        }
                    }
                    if let result = activation["node_result"], let description = WorkflowNodePresentation.summary(result.rendered()) {
                        Text("Result").font(.pb(.secondary, weight: .semibold))
                        Text(description).font(.pb(.secondary)).textSelection(.enabled)
                    }
                    if activation["role"]?.stringValue == "node", let id = activation["id"]?.stringValue {
                        Button("Show activity") { viewModel.selectActivation(id) }.buttonStyle(QuietButtonStyle())
                    }
                    ForEach(Array(WorkflowJSON.objects(activation["tasks"]).enumerated()), id: \.offset) { _, task in
                        let attempt = WorkflowExecutionAttempts.fallbackIndices(activation)[task["task_id"]?.stringValue ?? ""] ?? 0
                        HStack(alignment: .top, spacing: PbRadius.Metrics.spacing6) {
                            BackendDot(backend: task["candidate"]?["backend"]?.stringValue ?? "")
                            VStack(alignment: .leading, spacing: PbRadius.Metrics.rowLineSpacing) {
                                Text("\(attempt == 0 ? "Primary" : "Fallback \(attempt)"): \(task["candidate"]?["backend"]?.stringValue ?? "agent")")
                                Text(task["status"]?.stringValue ?? "").foregroundStyle(Color.secondaryText)
                                if let reason = task["reason"]?.stringValue {
                                    Text(reason).foregroundStyle(Color.secondaryText)
                                }
                                ForEach(Array(WorkflowContextDelivery(task: task).lines.enumerated()), id: \.offset) { _, line in
                                    Text(line).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                                }
                            }.font(.pb(.caption))
                        }
                    }
                }
.padding(PbRadius.Metrics.spacing10)
.background(Color.composerFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
            }
        }
    }

    @ViewBuilder
    func executionSessionDetails(_ activation: [String: JSONValue]) -> some View {
        let execution = WorkflowExecutionPresentation(raw: activation)
        Text(execution.label).font(.pb(.caption, weight: .semibold))
        if let reason = execution.fallbackReason {
            Text(reason).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
        }
        if execution.isSubagent {
            if let owner = execution.ownerTaskID {
                Button("Open owning orchestrator") { viewModel.openOwnerTask(owner) }.buttonStyle(QuietButtonStyle())
            } else {
                Text("Owning orchestrator history unavailable").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
            if execution.activityLimited {
                Text("Activity limited").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        if let mode = activation["execution_session_mode"]?.stringValue {
            Text("Session: " + mode.replacingOccurrences(of: "_", with: " "))
                .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
        }
        if let reason = activation["session_reason"]?.stringValue {
            Text(reason).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
        }
    }

}
