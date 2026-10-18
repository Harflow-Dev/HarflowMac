import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowRunDiagnostics

/// Durable scheduler diagnostics remain visible after a decision correction or checkout wait.
struct WorkflowRunDiagnostics: View {
    let run: WorkflowRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
            if let permissions = run.orchestratorPermissions {
                WorkflowPermissionsView(model: permissions)
            }
            if let wait = run.raw["checkout_wait"]?.objectValue {
                Label(wait["reason"]?.stringValue ?? "Waiting for another workflow to release the checkout", systemImage: "clock")
            }
            if let error = WorkflowJSON.objects(run.raw["decision_errors"]).last {
                Label("Decision attempt \(error["attempt"]?.intValue ?? 0): \(error["error"]?.stringValue ?? "Decision rejected")",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warningFG)
            }
            ForEach(Array(WorkflowJSON.objects(run.raw["pending"]).enumerated()), id: \.offset) { _, token in
                if let attempt = token["decision_attempts"]?.intValue {
                    Text("Decision attempts: \(attempt) / \(run.raw["definition"]?["max_decision_attempts"]?.intValue ?? 3)")
                }
            }
        }
        .font(.pb(.caption))
        .foregroundStyle(Color.secondaryText)
        .textSelection(.enabled)
    }
}

#if DEBUG
#Preview("Workflow diagnostics - light") {
    WorkflowRunDiagnostics(run: WorkflowRunModel(raw: ["decision_errors": .array([
        .object(["attempt": .number(1), "error": .string("Structural continuations do not choose sessions")])
    ])]))
.padding()
.preferredColorScheme(.light)
}

#Preview("Workflow diagnostics - dark") {
    WorkflowRunDiagnostics(run: WorkflowRunModel(raw: [
        "checkout_wait": .object(["reason": .string("Waiting for another workflow to release the checkout")]),
        "decision_errors": .array([
            .object(["attempt": .number(2), "error": .string("Decision rejected")])
        ]),
        "pending": .array([.object(["decision_attempts": .number(2)])]),
        "definition": .object(["max_decision_attempts": .number(3)])
    ]))
.padding()
.preferredColorScheme(.dark)
}
#endif
