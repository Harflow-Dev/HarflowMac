import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowPlanProgress

/// The checklist progress projection: the existing completed-status definition, a clamped
/// fraction, and zero for an empty plan. Pure and testable.
enum WorkflowPlanProgress {
    static func completedCount(_ tasks: [[String: JSONValue]]) -> Int {
        tasks.filter { $0["status"]?.stringValue == "completed" }.count
    }

    static func fraction(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(max(0, completed)) / Double(total))
    }
}

struct WorkflowRunPlan: View {
    let run: WorkflowRunModel
    @State private var showsTasks = true

    private var completed: Int { WorkflowPlanProgress.completedCount(run.tasks) }

    var body: some View {
        DisclosureGroup(isExpanded: $showsTasks) {
            ScrollView {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                    if run.tasks.isEmpty {
                        Text(run.emptyChecklistPresentation.title)
                            .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                    }
                    if run.tasks.isEmpty, let reason = run.emptyChecklistPresentation.reason, !reason.isEmpty {
                        Text(reason).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                    }
                    ForEach(run.tasks.compactMap(WorkflowPlanEntry.init)) { entry in
                        let task = entry.raw
                        HStack(alignment: .top, spacing: PbRadius.Metrics.spacing8) {
                            let done = task["status"]?.stringValue == "completed"
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? Color.doneGreen : Color.secondaryText)
                                .accessibilityLabel(done ? "Completed by orchestrator" : "Pending")
                            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                                Text(task["title"]?.stringValue ?? task["id"]?.stringValue ?? "Task")
                                    .font(.pb(.body, weight: .medium))
                                if let description = task["description"]?.stringValue, !description.isEmpty {
                                    Text(description).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                                }
                                if let reason = task["reason"]?.stringValue, !reason.isEmpty {
                                    Text(reason).font(.pb(.caption)).foregroundStyle(Color.tertiaryText).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, PbRadius.Metrics.spacing6)
                // The document probe (§6.4): inside the checklist's own document.
                .background(ScrollChrome())
            }.frame(maxHeight: PbRadius.Metrics.workflowRunActivityMinimumHeight)
        } label: {
            // The existing completed/total projection, tabular, with the design's 4 pt progress
            // strip; the checklist's disclosure behavior and empty-state honesty are unchanged.
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    Text(run.tasks.isEmpty ? "Plan" : "Plan · \(completed) of \(run.tasks.count) completed")
                        .font(.pb(.secondary, weight: .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                if !run.tasks.isEmpty {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.neutralFill)
                            Capsule()
                                .fill(Color.doneGreen)
                                .frame(width: proxy.size.width * WorkflowPlanProgress.fraction(completed: completed, total: run.tasks.count))
                        }
                    }
                    .frame(height: PbRadius.Metrics.workflowPlanProgressHeight)
                    .accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.pb(.secondary, weight: .medium))
    }

}

struct WorkflowPlanEntry: Identifiable {
    let id: String
    let raw: [String: JSONValue]
    init?(_ raw: [String: JSONValue]) {
        guard let id = raw["id"]?.stringValue else { return nil }
        self.id = id
        self.raw = raw
    }
}

#if DEBUG
private struct WorkflowRunPlanPreview: View {
    var empty = false
    var body: some View {
        WorkflowRunPlan(run: WorkflowRunModel(raw: empty ? [:] : [
            "tasks": .array([
                .object([
                    "id": .string("tests"),
                    "title": .string("Add regression coverage"),
                    "status": .string("completed"),
                    "reason": .string("Orchestrator confirmed the successful test result.")
                ]),
                .object(["id": .string("fix"), "title": .string("Implement the change"), "status": .string("pending")])
            ])
        ]))
        .padding()
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
    }
}

#Preview("Workflow plan - light") { WorkflowRunPlanPreview().preferredColorScheme(.light) }
#Preview("Workflow plan - dark") { WorkflowRunPlanPreview().preferredColorScheme(.dark) }
#Preview("Workflow plan - empty") { WorkflowRunPlanPreview(empty: true).preferredColorScheme(.dark) }
#endif
