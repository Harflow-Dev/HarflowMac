import Foundation

// MARK: - ArtifactRegisteredObservation

/// Stat identity recorded at registration; absent on engines before `task-artifacts.v1` added it.
/// The JSON model stores numbers as doubles, so integers are exact only up to 2^53. `device`, `inode`
/// and `size` stay within that range in practice; the nanosecond modification time does not, so it is
/// exposed only as an approximate value.
public struct ArtifactRegisteredObservation: Equatable, Sendable {
    public let device: Int64
    public let inode: Int64
    public let size: Int64
    /// Approximate: values above 2^53 lose precision. Not for identity or equality comparisons.
    public let approximateMtimeNS: Double

    init?(raw: [String: JSONValue]) {
        guard let device = WireFields.integer(raw["device"]), let inode = WireFields.integer(raw["inode"]),
              let size = WireFields.integer(raw["size"]),
              case .number(let mtime, true)? = raw["mtime_ns"], mtime.isFinite else { return nil }
        self.device = device
        self.inode = inode
        self.size = size
        approximateMtimeNS = mtime
    }
}

// MARK: - ArtifactErrorReason

/// Optional `artifact_error` reason from `task-artifacts.v1`; plain `artifact_error` refusals carry none.
public enum ArtifactErrorReason: Equatable, Sendable {
    case cursorInvalid, cursorStale, ownershipPreparing
    case unrecognized(String)

    init(_ raw: String) {
        switch raw {
        case "cursor_invalid": self = .cursorInvalid
        case "cursor_stale": self = .cursorStale
        case "ownership_preparing": self = .ownershipPreparing
        default: self = .unrecognized(raw)
        }
    }
}

public extension ToolError {
    /// `absent` without `data.reason` or for other refusals; `malformed` when `reason` is not a string.
    var artifactErrorReason: WireObservation<ArtifactErrorReason> {
        guard case .structuredRefusal(let code, _, let data) = self, code == "artifact_error",
              let value = data["reason"] else { return .absent }
        guard let text = value.stringValue else { return .malformed }
        return .present(ArtifactErrorReason(text))
    }
}

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
    public let workflow: WorkflowArtifactBinding?
    public let observedAt: String
    /// Nil only when the key is absent; a present but damaged value rejects the item.
    public let registeredObservation: ArtifactRegisteredObservation?
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
        if let value = raw["workflow"] {
            guard let object = value.objectValue, let binding = WorkflowArtifactBinding(raw: object, taskID: taskID) else { return nil }
            workflow = binding
        } else {
            workflow = nil
        }
        if let value = raw["registered_observation"] {
            guard let object = value.objectValue, let observation = ArtifactRegisteredObservation(raw: object) else { return nil }
            registeredObservation = observation
        } else {
            registeredObservation = nil
        }
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
        return await result("task-artifacts", options: options, positionals: [taskID],
                     requiringCapability: CtlCapability.taskArtifacts).flatMap { raw in
            guard let page = TaskArtifactPage(raw: raw, taskID: taskID) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Malformed artifact metadata page"))
            }
            return .success(page)
        }
    }
}
