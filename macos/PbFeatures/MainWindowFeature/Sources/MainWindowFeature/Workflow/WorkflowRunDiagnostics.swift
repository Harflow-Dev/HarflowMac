import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowRunDiagnostics

/// Durable scheduler diagnostics remain visible after a decision correction or checkout wait.
struct WorkflowRunDiagnostics: View {
    let run: WorkflowRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
#Preview("Workflow diagnostics") {
    WorkflowRunDiagnostics(run: WorkflowRunModel(raw: ["decision_errors": .array([
        .object(["attempt": .number(1), "error": .string("Structural continuations do not choose sessions")])
    ])])).padding()
}
#endif
