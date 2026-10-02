import MonitorCore

// MARK: - WorkflowVM Starter

extension WorkflowVM {
    static func candidateOptions(_ candidate: [String: JSONValue]) -> [String] {
        ["backend", "model", "reasoning_effort", "max_turns"].compactMap { key in
            guard let value = candidate[key], value != .null else {
                return nil
            }
            let text = value.stringValue ?? value.intValue.map(String.init) ?? ""
            guard !text.isEmpty else {
                return nil
            }
            return "--\(key.replacingOccurrences(of: "_", with: "-"))=\(text)"
        }
    }

    static func message(_ error: Error) -> String { (error as? ToolError)?.message ?? error.localizedDescription }

    static func starterDefinition() -> [String: JSONValue] {
        let steps = ["start", "planning", "implementation", "review", "end"]
        // Compact terminals and agent boxes share a center line and equal 50-point gaps.
        var nextX: Double = 68
        let nodes: [JSONValue] = steps.map { role in
            let terminal = ["start", "end"].contains(role)
            let width: Double = terminal ? 72 : 200
            let height: Double = terminal ? 72 : 92
            let position: JSONValue = .object(["x": .number(nextX), "y": .number(146 - height / 2)])
            nextX += width + 50
            var node: [String: JSONValue] = [
                "id": .string(role), "title": .string(role == "planning" ? "Plan" : role.capitalized),
                "type": .string(["start", "end"].contains(role) ? role : "agent"),
                "branch_mode": .string("auto"),
                "position": position
            ]
            if node["type"] == .string("agent") {
                node["role"] = .string(role)
                node["instructions"] = .string(Self.starterInstructions(role))
                node["agent"] = .object(["backend": .string("codex"), "fallbacks": .array([])])
                node["freedom"] = .string(WorkflowAccess.defaultLevel(for: role))
                node["session_mode"] = .string("resume")
                node["branch_mode"] = .string("auto")
                node["max_attempts"] = .number(3)
            }
            return .object(node)
        }
        var connections: [JSONValue] = zip(steps, steps.dropFirst()).map { source, target in
            var edge: [String: JSONValue] = ["id": .string("\(source)-\(target)"), "source": .string(source), "target": .string(target)]
            if source == "review" { edge["condition"] = .string("The review approves the implementation and validation; no changes remain.") }
            return .object(edge)
        }
        connections.append(.object([
            "id": .string("review-implementation"), "source": .string("review"), "target": .string("implementation"),
            "condition": .string("The review finds concrete changes needed. Implement the review feedback, then request another review.")
        ]))
        return ["description": .string(""), "max_parallel": .number(4), "max_transitions": .number(100),
                "orchestrator": .object(["backend": .string("codex"), "fallbacks": .array([])]),
                "nodes": .array(nodes), "connections": .array(connections)]
    }

    private static func starterInstructions(_ role: String) -> String {
        switch role {
        case "planning": "Inspect the task and produce a concrete task list. Do not modify files."
        case "implementation": "Implement the planned tasks. Report completed task IDs and observed validation evidence."
        case "review": "Review the implementation and validation. Report approval or concrete changes needed. Do not modify files."
        default: ""
        }
    }

}
