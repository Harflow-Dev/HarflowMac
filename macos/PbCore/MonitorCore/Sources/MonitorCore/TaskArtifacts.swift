import Foundation

// MARK: - TaskArtifact

/// Registered metadata, never evidence that a task succeeded or permission to open a file.
public struct TaskArtifact: Equatable, Sendable, Identifiable {
    public let artifactID: String
    public let taskID: String
    public let kind: String
    public let note: String
    public let path: String
    public let registeredAt: String
    public let registrar: String
    public let availability: String
    public let observedAt: String
    public var id: String { taskID + ":" + artifactID }

    public init?(raw: [String: JSONValue], taskID: String) {
        guard let artifactID = raw["artifact_id"]?.stringValue, !artifactID.isEmpty,
              raw["task_id"]?.stringValue == taskID,
              let kind = raw["kind"]?.stringValue, let note = raw["note"]?.stringValue,
              let path = raw["path"]?.stringValue, let registeredAt = raw["registered_at"]?.stringValue,
              let provenance = raw["provenance"]?.objectValue,
              provenance["task_id"]?.stringValue == taskID,
              let registrar = provenance["method"]?.stringValue,
              let observation = raw["availability"]?.objectValue,
              let availability = observation["state"]?.stringValue,
              ["available", "deleted", "changed", "unavailable"].contains(availability),
              let observedAt = observation["observed_at"]?.stringValue else { return nil }
        self.artifactID = artifactID
        self.taskID = taskID
        self.kind = kind
        self.note = note
        self.path = path
        self.registeredAt = registeredAt
        self.registrar = registrar
        self.availability = availability
        self.observedAt = observedAt
    }
}

// MARK: - TaskArtifactPage

/// One bounded metadata page belonging to exactly one task.
public struct TaskArtifactPage: Equatable, Sendable {
    public let taskID: String
    public let items: [TaskArtifact]
    public let nextCursor: String?
    public let hasMore: Bool
    public let state: String
    public let count: Int

    public init?(raw: [String: JSONValue], taskID: String) {
        guard JSONValue.object(raw).rendered().utf8.count <= 64 << 10,
              raw["task_id"]?.stringValue == taskID,
              let values = raw["items"]?.arrayValue, values.count <= 50,
              let hasMore = raw["has_more"]?.boolValue,
              let state = raw["state"]?.stringValue, ["available", "unavailable"].contains(state),
              let count = raw["count"]?.intValue, count >= 0,
              raw["next_cursor"] == .null || raw["next_cursor"]?.stringValue != nil else { return nil }
        let items = values.compactMap { $0.objectValue.flatMap { TaskArtifact(raw: $0, taskID: taskID) } }
        let cursor = raw["next_cursor"]?.stringValue
        guard items.count == values.count, Set(items.map(\.id)).count == items.count,
              !hasMore || cursor?.isEmpty == false else { return nil }
        self.taskID = taskID
        self.items = items
        nextCursor = cursor
        self.hasMore = hasMore
        self.state = state
        self.count = count
    }
}

public extension CtlClient {
    /// Reads metadata only. The bridge observes availability without loading artifact contents.
    func taskArtifacts(_ taskID: String, cursor: String? = nil) async -> Result<TaskArtifactPage, ToolError> {
        var options = ["--limit=20"]
        if let cursor { options.append("--cursor=\(cursor)") }
        return await result("task-artifacts", options: options, positionals: [taskID]).flatMap { raw in
            guard let page = TaskArtifactPage(raw: raw, taskID: taskID) else {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Malformed artifact metadata page"))
            }
            return .success(page)
        }
    }
}
