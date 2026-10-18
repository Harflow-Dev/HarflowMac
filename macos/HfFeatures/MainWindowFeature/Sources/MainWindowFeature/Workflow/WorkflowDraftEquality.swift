import MonitorCore

// MARK: - WorkflowDraftEquality

/// Explicit false and the default absent optional flag represent the same agent behavior.
enum WorkflowDraftEquality {
    static func matches(_ lhs: [String: JSONValue], _ rhs: [String: JSONValue]) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ definition: [String: JSONValue]) -> [String: JSONValue] {
        guard let nodes = definition["nodes"]?.arrayValue else { return definition }
        var normalized = definition
        normalized["nodes"] = .array(nodes.map { value in
            guard var node = value.objectValue, node["type"]?.stringValue == "agent", node["optional"]?.boolValue == false else { return value }
            node.removeValue(forKey: "optional")
            return .object(node)
        })
        return normalized
    }
}
