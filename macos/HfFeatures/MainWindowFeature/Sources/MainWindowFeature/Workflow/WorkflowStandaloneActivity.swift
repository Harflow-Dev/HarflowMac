import MonitorCore

// MARK: - WorkflowStandaloneActivity

/// Standalone liveness requires a confirmed running task, rather than an activation reservation.
enum WorkflowStandaloneActivity {
    static func isRunning(_ activation: [String: JSONValue]) -> Bool {
        WorkflowJSON.objects(activation["tasks"]).contains { $0["status"]?.stringValue == "running" }
    }

    static func orchestratorActivations(_ run: [String: JSONValue]) -> [[String: JSONValue]] {
        WorkflowJSON.objects(run["activations"]).filter { $0["role"]?.stringValue == "orchestrator" }
    }

    static func statuses(run: [String: JSONValue]) -> [String: String] {
        guard run["kind"]?.stringValue != "builder" else { return [:] }
        let activations = WorkflowJSON.objects(run["activations"])
        let running = activations.filter(isRunning)
        let runningIDs = Set(running.compactMap { $0["id"]?.stringValue })
        var result = [WorkflowStandalone.orchestratorID: running.contains { $0["role"]?.stringValue == "orchestrator" } ? "running" : "pending"]
        for node in WorkflowJSON.objects(run["on_demand_nodes"]) {
            if let id = node["node_id"]?.stringValue { result[id] = "pending" }
        }
        for call in WorkflowJSON.objects(run["on_demand_calls"]) {
            if let nodeID = call["node_id"]?.stringValue, let id = call["execution_id"]?.stringValue, runningIDs.contains(id) {
                result[nodeID] = "running"
            }
        }
        return result
    }

    static func status(nodeID: String, run: [String: JSONValue]) -> String {
        statuses(run: run)[nodeID] ?? "pending"
    }

}

// MARK: - Standalone inspector projection

extension WorkflowRunSidebarPresentation {
    mutating func selectStandalone(run: [String: JSONValue], nodeID: String, attemptID: String?) -> Bool {
        let relevant: [[String: JSONValue]]
        let label: String
        var callNumbers: [String: Int] = [:]
        if nodeID == WorkflowStandalone.orchestratorID {
            node = ["id": .string(nodeID), "title": .string("Orchestrator"), "type": .string("agent")]
            relevant = WorkflowStandaloneActivity.orchestratorActivations(run)
            label = "Decision"
        } else {
            guard let entry = WorkflowJSON.objects(run["on_demand_nodes"]).first(where: { $0["node_id"]?.stringValue == nodeID }) else { return false }
            var raw = entry
            raw["id"] = entry["node_id"]
            node = raw
            isOnDemand = true
            calls = WorkflowJSON.objects(run["on_demand_calls"]).filter { $0["node_id"]?.stringValue == nodeID }
            let activations = WorkflowJSON.objects(run["activations"])
            // Missing associations stay visible in call history, never borrow another execution.
            relevant = calls.compactMap { call in
                if let id = call["execution_id"]?.stringValue,
                   let activation = activations.first(where: { $0["id"]?.stringValue == id }) { return activation }
                guard let id = call["id"]?.stringValue else { return nil }
                return ["id": .string("unavailable:" + id), "status": call["status"] ?? .string("unknown"), "tasks": .array([])]
            }
            for (index, activation) in relevant.enumerated() {
                guard let id = activation["id"]?.stringValue else { continue }
                let call = calls.first { call in
                    call["execution_id"]?.stringValue == id || call["id"]?.stringValue.map { "unavailable:" + $0 } == id
                }
                let number = call?["call_number"]?.intValue ?? index + 1
                callNumbers[id] = number > 0 ? number : index + 1
            }
            label = "Call"
        }
        attempts = relevant.enumerated().compactMap { index, raw in
            guard let id = raw["id"]?.stringValue else { return nil }
            return Attempt(id: id, title: "\(label) \(callNumbers[id] ?? index + 1) · \(raw["status"]?.stringValue ?? "unknown")", raw: raw)
        }
        activationID = attemptID.flatMap { chosen in attempts.contains { $0.id == chosen } ? chosen : nil }
            ?? relevant.last(where: WorkflowStandaloneActivity.isRunning)?["id"]?.stringValue
            ?? attempts.last?.id
        if let activation {
            taskIDs = WorkflowJSON.objects(activation["tasks"])
                .compactMap { $0["task_id"]?.stringValue }
        }
        return true
    }
}
