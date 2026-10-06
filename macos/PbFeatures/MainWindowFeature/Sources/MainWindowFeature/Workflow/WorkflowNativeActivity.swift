import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowNativeActivityModel

/// Native execution activity has no process task or independent terminal handoff.
struct WorkflowNativeActivityModel {
    let executionID: String
    let title: String
    let status: String
    let limited: Bool
    var items: [TimelineItem] = []
    var error: String?
    var hasEarlierActivity = false
}

// MARK: - WorkflowNativeActivityView

struct WorkflowNativeActivityView: View {
    let model: WorkflowNativeActivityModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.title + " · Subagent").font(.pb(.body, weight: .semibold))
                Text(model.status).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                if model.limited { Text("Activity limited").font(.pb(.caption)).foregroundStyle(Color.secondaryText) }
                if let error = model.error { Text(error).font(.pb(.caption)).foregroundStyle(Color.secondaryText) }
                if model.hasEarlierActivity { Text("Showing the latest 200 activity events.").font(.pb(.caption)).foregroundStyle(Color.secondaryText) }
                ForEach(model.items) { item in
                    TimelineRow(model: TimelineRowModel(item: item, start: nil, live: ["running", "launch_requested"].contains(model.status)))
                }
            }
.padding(16)
.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - WorkflowVM native activity

extension WorkflowVM {
    func updateActivityMembership() {
        updateNativeActivity()
        let activations = selectedRun?.activations ?? []
        let relevant = activations.filter { ["node", "builder"].contains($0["role"]?.stringValue ?? "") }
        var latestByNode: [String: [String: JSONValue]] = [:]
        for activation in relevant { latestByNode[activation["node_id"]?.stringValue ?? "builder"] = activation }
        let visible = selectedActivationID.map { selected in relevant.filter { $0["id"]?.stringValue == selected } } ?? Array(latestByNode.values)
        let tasks = relevant.flatMap { headlessTaskIDs($0) }
        let focused = Set(visible.flatMap { headlessTaskIDs($0) })
        var titles: [String: String] = [:]
        for activation in relevant {
            let nodeID = activation["node_id"]?.stringValue ?? ""
            let title = nodes.first { $0.id == nodeID }?.name ?? "Workflow builder"
            let index = relevant.filter { $0["node_id"]?.stringValue == nodeID }.firstIndex { $0["id"] == activation["id"] }.map { $0 + 1 } ?? 1
            let fallbackIndices = WorkflowExecutionAttempts.fallbackIndices(activation)
            for task in WorkflowJSON.objects(activation["tasks"]) {
                if let id = task["task_id"]?.stringValue {
                    let fallback = fallbackIndices[id] ?? 0
                    titles[id] = "\(title) · \(index)\(fallback > 0 ? " · Fallback \(fallback)" : "")"
                }
            }
        }
        var seen = Set<String>()
        parallel.setWorkflowTaskIDs(tasks.filter { seen.insert($0).inserted }, focusedTaskIDs: focused, titles: titles)
    }

    private func headlessTaskIDs(_ activation: [String: JSONValue]) -> [String] {
        WorkflowJSON.objects(activation["tasks"])
            .filter { $0["execution_kind"]?.stringValue != "native_subagent" }
            .compactMap { $0["task_id"]?.stringValue }
    }

    func openOwnerTask(_ id: String) { routing.selectTask(id) }

    func selectActivation(_ id: String?) {
        selectedActivationID = id
        updateActivityMembership()
    }

    func updateNativeActivity() {
        nativeActivityTask?.cancel()
        nativeActivityTask = nil
        guard let run = selectedRun,
              let activation = run.activations.last(where: { activation in
                  if let selectedActivationID { return activation["id"]?.stringValue == selectedActivationID }
                  return activation["node_id"]?.stringValue == selectedNodeID && activation["role"]?.stringValue == "node"
              }), let executionID = activation["id"]?.stringValue,
              WorkflowExecutionPresentation(raw: activation).isSubagent else {
            nativeActivity = nil
            return
        }
        let projection = WorkflowExecutionPresentation(raw: activation)
        let old = nativeActivity?.executionID == executionID ? nativeActivity?.items ?? [] : []
        nativeActivity = WorkflowNativeActivityModel(executionID: executionID, title: selectedNode?.name ?? "Workflow node",
            status: activation["status"]?.stringValue ?? "unknown", limited: projection.activityLimited, items: old)
        nativeActivityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await useCase.command("inspect", options: ["--view=activity", "--limit=200"], positionals: [run.id, executionID])
                guard !Task.isCancelled, selectedRun?.id == run.id, nativeActivity?.executionID == executionID else { return }
                let events = (page["events"]?.arrayValue ?? []).compactMap { TaskEvent(line: $0.rendered()) }
                nativeActivity?.items = Timeline.items(from: events)
                nativeActivity?.hasEarlierActivity = page["has_more"]?.boolValue ?? false
            } catch {
                guard !Task.isCancelled, selectedRun?.id == run.id, nativeActivity?.executionID == executionID else { return }
                nativeActivity?.error = "Unable to load subagent activity. " + Self.message(error)
            }
        }
    }
}

#if DEBUG
#Preview("Native subagent activity") {
    WorkflowNativeActivityView(model: .init(executionID: "example", title: "Review", status: "running", limited: true))
}
#endif
