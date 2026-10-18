import MonitorCore

// MARK: - WorkflowAccess

enum WorkflowAccess {
    static let levels = ["read_only", "write_in_repo", "publish", "unrestricted"]

    static func defaultLevel(for role: String) -> String {
        switch role {
        case "implementation": "write_in_repo"
        case "task": "publish"
        default: "read_only"
        }
    }

    static func allowedLevels(for role: String) -> [String] {
        role == "implementation" ? levels.filter { $0 != "read_only" } : levels
    }

    static func title(_ level: String) -> String {
        switch level {
        case "read_only": "Read only"
        case "write_in_repo": "Write in repository"
        case "publish": "Publish"
        case "unrestricted": "Unrestricted"
        default: level
        }
    }

    static func updating(_ node: [String: JSONValue], key: String, value: JSONValue?) -> [String: JSONValue] {
        var result = node
        let role = node["role"]?.stringValue ?? "task"
        if key == "freedom", let level = value?.stringValue, !allowedLevels(for: role).contains(level) { return node }
        result[key] = value
        if key == "role", let newRole = value?.stringValue {
            let level = result["freedom"]?.stringValue ?? defaultLevel(for: newRole)
            if !allowedLevels(for: newRole).contains(level) || result["freedom"] == nil {
                result["freedom"] = .string(defaultLevel(for: newRole))
            }
        }
        return result
    }
}
