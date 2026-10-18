import PbUI
import SwiftUI

// MARK: - WorkflowGoalView

struct WorkflowGoalView<VM: WorkflowViewModel>: View {
    var viewModel: VM
    let run: WorkflowRunModel
    @State private var revisionText = ""
    @State private var editing = false
    @State private var expectedRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            if let goal = run.goal {
                DisclosureGroup("Goal · revision \(run.goalRevision)") {
                    ScrollView {
                        Text(goal)
.font(.pb(.body))
.textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ScrollChrome())
                    }.frame(maxHeight: PbRadius.Metrics.workflowRunActivityMinimumHeight)
                    if let assessment = run.goalAssessment {
                        Text("Assessment: \(assessment["status"]?.stringValue ?? "unverifiable")")
                            .font(.pb(.secondary, weight: .medium))
                        if let reason = assessment["reason"]?.stringValue { Text(reason).textSelection(.enabled) }
                        ForEach(Array((assessment["evidence_refs"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, value in
                            if let text = value.stringValue { Text(text).textSelection(.enabled) }
                        }
                    }
                    DisclosureGroup("Revision history") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                        ForEach(Array(run.goalHistory.enumerated()), id: \.offset) { _, item in
                            Text("Revision \(item["revision"]?.intValue ?? 0)").font(.pb(.secondary, weight: .medium))
                            Text(item["goal"]?.stringValue ?? "").textSelection(.enabled)
                        }
                            }
.frame(maxWidth: .infinity, alignment: .leading)
                                .background(ScrollChrome())
                        }.frame(maxHeight: PbRadius.Metrics.workflowRunActivityMinimumHeight)
                    }
                }
            }
            if run.canReviseGoal {
                if editing {
                    TextEditor(text: $revisionText)
.font(.pb(.body))
.scrollChromeScope()
                        .frame(minHeight: PbRadius.Metrics.sidebarSearchMinimumWidth)
                        .accessibilityLabel("Revised workflow goal")
                    HStack {
                        Button("Cancel") { editing = false }.buttonStyle(QuietButtonStyle())
                        Button("Save goal") {
                            viewModel.reviseGoal(revisionText, runID: run.id, expectedRevision: expectedRevision)
                        }.disabled(viewModel.isBusy || revisionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button("Revise goal…") {
                        revisionText = run.goal ?? ""
                        expectedRevision = run.goalRevision
                        editing = true
                    }
                        .buttonStyle(QuietButtonStyle())
.disabled(viewModel.isBusy)
                }
            } else if let reason = run.goalRevisionReason {
                Text(reason).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            }
        }
        .font(.pb(.secondary))
        .onChange(of: run.id) { editing = false }
        .onChange(of: run.goalRevision) {
            if run.goal == revisionText { editing = false }
        }
    }
}

#if DEBUG
#Preview {
    let vm = WorkflowPreview.make(run: true)
    WorkflowGoalView(viewModel: vm, run: WorkflowRunModel(raw: ["goal": .string("Verify the release."), "goal_revision": .number(1)]))
}
#endif
