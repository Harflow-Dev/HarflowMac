import AppKit
import Foundation
import MonitorCore

// MARK: - WorkflowRunSidebarPresentation

/// Immutable run inspector state, derived from persisted run snapshots outside the main actor.
struct WorkflowRunSidebarPresentation: Equatable, Sendable {
    struct Attempt: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let raw: [String: JSONValue]
    }

    var node: [String: JSONValue]?
    var attempts: [Attempt] = []
    var activationID: String?
    var calls: [[String: JSONValue]] = []
    var isOnDemand = false
    var childRunID: String?
    var taskIDs: [String] = []
    var allTaskIDs: [String] = []
    var latestTaskIDs: Set<String> = []
    var titles: [String: String] = [:]
    var selectedNodeExists = true
    var isDefault: Bool { node == nil }
    var announcementIdentity: String { (node?["id"]?.stringValue ?? "default") + ":" + (activationID ?? "") }
    var title: String { node?["title"]?.stringValue ?? node?["id"]?.stringValue ?? "Workflow" }
    var activation: [String: JSONValue]? { attempts.first { $0.id == activationID }?.raw }

    static func build(run: [String: JSONValue], nodeID: String?, attemptID: String?) -> Self {
        var result = Self()
        let definition = run["definition"]?.objectValue ?? [:]
        let nodes = WorkflowJSON.objects(definition["nodes"])
        let activations = WorkflowJSON.objects(run["activations"])
        let workers = activations.filter { ["node", "builder"].contains($0["role"]?.stringValue ?? "") }
        var latest: [String: [String: JSONValue]] = [:]
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for activation in workers {
            let id = activation["node_id"]?.stringValue ?? "builder"
            latest[id] = activation
            counts[id, default: 0] += 1
            let title = nodes.first { $0["id"]?.stringValue == id }?["title"]?.stringValue ?? id
            let fallbacks = WorkflowExecutionAttempts.fallbackIndices(activation)
            for task in WorkflowJSON.objects(activation["tasks"]) where task["execution_kind"]?.stringValue != "native_subagent" {
                guard let taskID = task["task_id"]?.stringValue else { continue }
                if seen.insert(taskID).inserted { result.allTaskIDs.append(taskID) }
                let fallback = fallbacks[taskID] ?? 0
                result.titles[taskID] = "\(title) · \(counts[id] ?? 1)" + (fallback > 0 ? " · Fallback \(fallback)" : "")
            }
        }
        result.latestTaskIDs = Set(latest.values.flatMap(headlessTaskIDs))
        guard let nodeID else { return result }
        let standalone = WorkflowJSON.objects(run["on_demand_nodes"]).map { entry in
            var node = entry
            node["id"] = entry["node_id"]
            return node
        }
        if let node = standalone.first(where: { $0["id"]?.stringValue == nodeID }) {
            result.node = node
            result.isOnDemand = true
            result.calls = WorkflowJSON.objects(run["on_demand_calls"]).filter { $0["node_id"]?.stringValue == nodeID }
            return result
        }
        guard let node = nodes.first(where: { $0["id"]?.stringValue == nodeID }) else {
            result.selectedNodeExists = nodeID == WorkflowStandalone.orchestratorID
            return result
        }
        guard ["agent", "workflow"].contains(node["type"]?.stringValue ?? "agent") else { return result }
        result.node = node
        let relevant = workers.filter { $0["node_id"]?.stringValue == nodeID && $0["role"]?.stringValue == "node" }
        result.attempts = relevant.enumerated().compactMap { index, raw in
            guard let id = raw["id"]?.stringValue else { return nil }
            return Attempt(id: id, title: "Attempt \(index + 1) · \(raw["status"]?.stringValue ?? "unknown")", raw: raw)
        }
        result.activationID = attemptID.flatMap { chosen in result.attempts.contains { $0.id == chosen } ? chosen : nil }
            ?? result.attempts.last { ["running", "launch_requested"].contains($0.raw["status"]?.stringValue ?? "") }?.id
            ?? result.attempts.last?.id
        if let activation = result.activation {
            result.taskIDs = headlessTaskIDs(activation)
            result.childRunID = activation["invocation"]?["child_workflow_run_id"]?.stringValue
                ?? activation["child_workflow_run_id"]?.stringValue
                ?? activation["workflow_run_id"]?.stringValue
        }
        return result
    }

    private static func headlessTaskIDs(_ activation: [String: JSONValue]) -> [String] {
        WorkflowJSON.objects(activation["tasks"])
.filter { $0["execution_kind"]?.stringValue != "native_subagent" }
            .compactMap { $0["task_id"]?.stringValue }
    }
}

// MARK: - WorkflowVM sidebar lifecycle

extension WorkflowVM {
    func scheduleRunSidebar() {
        sidebarTask?.cancel()
        sidebarTask = nil
        let generation = UUID()
        sidebarGeneration = generation
        guard let runSnapshot = selectedRun, !runSnapshot.isBuilder else {
            clearRunSidebar()
            return
        }
        let run = runSnapshot.raw
        let runID = runSnapshot.id
        let nodeID = selectedNodeID
        let attemptID = selectedActivationID
        sidebarTask = Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) {
                WorkflowRunSidebarPresentation.build(run: run, nodeID: nodeID, attemptID: attemptID)
            }.value
            guard let self, !Task.isCancelled, sidebarGeneration == generation,
                  selectedRun?.id == runID, selectedNodeID == nodeID else { return }
            if !next.selectedNodeExists { selectedNodeID = nil; return }
            applyRunSidebar(next, runID: runID)
            if runSidebar.node?["id"]?.stringValue != nodeID { return }
            sidebarTask = nil
        }
    }

    private func clearRunSidebar() {
        for activity in activityCache.values { activity.didDisappear() }
        activityCache.removeAll()
        selectedActivity = nil
        activityRunID = nil
        nativeActivityTask?.cancel()
        nativeActivityTask = nil
        if nativeActivity != nil { nativeActivity = nil }
        let empty = WorkflowRunSidebarPresentation()
        if runSidebar != empty { runSidebar = empty }
    }

    private func applyRunSidebar(_ next: WorkflowRunSidebarPresentation, runID: String?) {
    if activityRunID != runID {
        for activity in activityCache.values { activity.didDisappear() }
        activityCache.removeAll()
        selectedActivity = nil
        activityRunID = runID
    }
    if selectedActivationID != nil, selectedActivationID != next.activationID { selectedActivationID = nil }
    if runSidebar != next { runSidebar = next }
    parallel.setWorkflowTaskIDs(next.allTaskIDs, focusedTaskIDs: next.latestTaskIDs, titles: next.titles)
    let key = next.node?["id"]?.stringValue.flatMap { id in next.activationID.map { id + ":" + $0 } }
    let activity = key.flatMap { key -> ParallelVM? in
        guard !next.taskIDs.isEmpty else { return nil }
        if let cached = activityCache[key] { return cached }
        let created = parallel.makeWorkflowActivity()
        activityCache[key] = created
        return created
    }
    if selectedActivity !== activity {
        selectedActivity?.suspendWorkflowActivity()
        selectedActivity = activity
    }
    activity?.setWorkflowTaskIDs(next.taskIDs, titles: next.titles)
    if runGraphVisible { activity?.didAppear() }
    if runGraphVisible { parallel.suspendWorkflowActivity() } else { parallel.didAppear() }
    updateNativeActivity()
    }

    func setRunGraphVisible(_ visible: Bool) {
        guard runGraphVisible != visible else { return }
        runGraphVisible = visible
        if visible {
            parallel.suspendWorkflowActivity()
            selectedActivity?.didAppear()
        } else {
            selectedActivity?.suspendWorkflowActivity()
            parallel.didAppear()
        }
        updateNativeActivity()
    }
}
