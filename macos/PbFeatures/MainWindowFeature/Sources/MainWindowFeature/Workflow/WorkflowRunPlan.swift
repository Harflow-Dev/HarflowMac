import MonitorCore
import PbUI
import SwiftUI

struct WorkflowRunPlan: View {
    let run: WorkflowRunModel
    @State private var showsTasks = true
    var body: some View {
        let completed = run.tasks.filter { $0["status"]?.stringValue == "completed" }.count
        return DisclosureGroup("Plan · \(completed) of \(run.tasks.count) completed", isExpanded: $showsTasks) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if run.tasks.isEmpty {
                        Text(["starting", "running"].contains(run.status) ? "Waiting for a plan…" : "No plan was provided for this run.")
                            .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
                    }
                    ForEach(run.tasks.compactMap(WorkflowPlanEntry.init)) { entry in
                        let task = entry.raw
                        HStack(alignment: .top, spacing: 8) {
                            let done = task["status"]?.stringValue == "completed"
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? Color.doneGreen : Color.secondaryText)
                                .accessibilityLabel(done ? "Completed by orchestrator" : "Pending")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task["title"]?.stringValue ?? task["id"]?.stringValue ?? "Task").font(.pb(.body))
                                if let description = task["description"]?.stringValue, !description.isEmpty {
                                    Text(description).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                                }
                                if let reason = task["reason"]?.stringValue, !reason.isEmpty {
                                    Text(reason).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                                }
                            }
                        }
                    }
                }
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, 6)
            }.frame(maxHeight: 240)
        }.font(.pb(.secondary, weight: .medium))
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
