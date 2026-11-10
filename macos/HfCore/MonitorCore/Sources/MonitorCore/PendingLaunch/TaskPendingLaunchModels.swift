import Foundation

// MARK: - TaskPendingLaunchWire

/// Admission bounds for public pending-launch reads, independent of process stdout capture.
public enum TaskPendingLaunchWire {
    public static let scope = "prerecord_launch_attempts_and_not_started"
    public static let maximumDocumentBytes = 128 * 1024
    public static let maximumCursorBytes = 4096

    /// Full engine identifier syntax; validation does not resolve prefixes or establish existence.
    public static func isFullID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte)
        }
        return (1 ... 64).contains(bytes.count) && bytes.first.map(alphanumeric) == true &&
            bytes.allSatisfy { alphanumeric($0) || $0 == 95 || $0 == 45 }
    }

    static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static func text(_ raw: [String: JSONValue], _ key: String, maximum: Int) -> String?? {
        guard let value = raw[key] else { return nil }
        if value == .null { return .some(nil) }
        guard let text = value.stringValue, text.utf8.count <= maximum else { return nil }
        return .some(text)
    }
}

// MARK: - TaskPendingLaunchMetadata

/// Qualified display metadata. Mechanism support and metadata never grant cancellation permission.
public struct TaskPendingLaunchMetadata: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case reserved, claimed, waitingForResources, granted, notStarted
        case unrecognized(String)

        init(_ value: String) {
            switch value {
            case "reserved": self = .reserved
            case "claimed": self = .claimed
            case "waiting_for_resources": self = .waitingForResources
            case "granted": self = .granted
            case "not_started": self = .notStarted
            default: self = .unrecognized(value)
            }
        }
    }

    public let generation: String
    public let state: State
    public let title: String?
    public let backend: String?
    public let repoPath: String?
    public let createdAt: String?
    public let notStartedReason: String?
    public let lineage: [String: String]
    public let resourceNames: [String]
    public let metadataTruncated: Bool

    init?(raw: [String: JSONValue]) {
        guard let generation = raw["generation"]?.stringValue, TaskPendingLaunchWire.hex(generation, count: 32),
              let state = raw["state"]?.stringValue, !state.isEmpty,
              let title = TaskPendingLaunchWire.text(raw, "title", maximum: 1024),
              let backend = TaskPendingLaunchWire.text(raw, "backend", maximum: 1024),
              let repoPath = TaskPendingLaunchWire.text(raw, "repo_path", maximum: 4096),
              let createdAt = TaskPendingLaunchWire.text(raw, "created_at", maximum: 1024),
              let reason = TaskPendingLaunchWire.text(raw, "not_started_reason", maximum: 1024),
              let lineage = raw["lineage"]?.objectValue,
              let resources = raw["resource_names"]?.arrayValue, resources.count <= 100,
              let truncated = raw["metadata_truncated"]?.boolValue else { return nil }
        let knownKeys: Set = ["spawned_by", "root_task_id", "parent_task_id", "chain_root_task_id"]
        var knownLineage: [String: String] = [:]
        for (key, value) in lineage where knownKeys.contains(key) {
            guard let id = value.stringValue, TaskPendingLaunchWire.isFullID(id) else { return nil }
            knownLineage[key] = id
        }
        let names = resources.compactMap(\.stringValue)
        guard names.count == resources.count, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { return nil }
        self.generation = generation
        self.state = State(state)
        self.title = title
        self.backend = backend
        self.repoPath = repoPath
        self.createdAt = createdAt
        self.notStartedReason = reason
        self.lineage = knownLineage
        self.resourceNames = names
        self.metadataTruncated = truncated
    }
}

// MARK: - TaskPendingLaunchItem

/// A row identity is a lookup target, never a trusted task label or cancellation grant.
public struct TaskPendingLaunchItem: Equatable, Sendable {
    public enum Disposition: Equatable, Sendable {
        case pending, recorded, notFound, refused, unknown
        case unrecognized(String)

        init(_ value: String) {
            switch value {
            case "pending": self = .pending
            case "recorded": self = .recorded
            case "not_found": self = .notFound
            case "refused": self = .refused
            case "unknown": self = .unknown
            default: self = .unrecognized(value)
            }
        }
    }

    public enum CancelSupport: Equatable, Sendable {
        case supported, unsupported
        case unrecognized(String)
    }

    public let taskID: String
    public let disposition: Disposition
    /// Nil for unknown states and deny-only dispositions; raw fields remain diagnostic evidence.
    public let launch: TaskPendingLaunchMetadata?
    public let cancelSupport: CancelSupport?
    public let code: String?
    public let check: String?
    public let raw: [String: JSONValue]

    /// This client cannot interpret a future disposition, launch state or cancel mechanism.
    /// Raw evidence remains available, but must not certify a comprehended inventory.
    public var hasUnsupportedObservations: Bool {
        if case .unrecognized = disposition { return true }
        if disposition == .pending, launch == nil { return true }
        if case .unrecognized = cancelSupport { return true }
        return false
    }

    public init?(raw: [String: JSONValue]) {
        guard let taskID = raw["task_id"]?.stringValue, TaskPendingLaunchWire.isFullID(taskID),
              let disposition = raw["disposition"]?.stringValue, !disposition.isEmpty else { return nil }
        self.taskID = taskID
        self.disposition = Disposition(disposition)
        self.raw = raw
        self.code = raw["code"]?.stringValue
        self.check = raw["check"]?.stringValue
        if disposition == "pending" {
            guard let object = raw["launch"]?.objectValue, let metadata = TaskPendingLaunchMetadata(raw: object),
                  let support = raw["cancel_support"]?.stringValue else { return nil }
            if case .unrecognized = metadata.state {
                self.launch = nil
                self.cancelSupport = nil
            } else {
                self.launch = metadata
                switch support {
                case "supported": self.cancelSupport = metadata.state == .notStarted ? .unsupported : .supported
                case "unsupported": self.cancelSupport = .unsupported
                default: self.cancelSupport = .unrecognized(support)
                }
            }
        } else {
            if disposition == "refused" || disposition == "unknown" {
                guard let code, !code.isEmpty, let check, !check.isEmpty else { return nil }
            }
            self.launch = nil
            self.cancelSupport = nil
        }
    }
}

// MARK: - TaskPendingLaunchLookup

/// Exact lookup evidence. Recorded requires a subsequent ordinary status read; not-found proves no settlement.
public struct TaskPendingLaunchLookup: Equatable, Sendable {
    public let observedAt: String
    public let item: TaskPendingLaunchItem
    public let raw: [String: JSONValue]

    public init?(raw: [String: JSONValue], requestedTaskID: String) {
        guard raw["scope"]?.stringValue == TaskPendingLaunchWire.scope,
              let observedAt = raw["observed_at"]?.stringValue, !observedAt.isEmpty,
              let item = TaskPendingLaunchItem(raw: raw), item.taskID == requestedTaskID else { return nil }
        self.observedAt = observedAt
        self.item = item
        self.raw = raw
    }
}

// MARK: - TaskPendingLaunchPage

/// One bounded page, never an atomic inventory or a certificate of prior traversal.
public struct TaskPendingLaunchPage: Equatable, Sendable {
    public enum Coverage: Equatable, Sendable {
        case complete, unknown
        case unrecognized(String)
    }

    public let observedAt: String
    public let items: [TaskPendingLaunchItem]
    public let namespaceRevision: String
    public let namespaceComplete: Bool
    public let coverage: Coverage
    public let invalidNameCount: Int
    public let examinedCount: Int
    public let hasMore: Bool
    public let nextCursor: String?
    public let bound: String?
    public let raw: [String: JSONValue]

    /// Independent of producer coverage: a complete producer traversal may contain values
    /// this client cannot interpret. Such a page cannot complete a comprehended inventory.
    public var hasUnsupportedObservations: Bool {
        if case .unrecognized = coverage { return true }
        return items.contains(where: \.hasUnsupportedObservations)
    }

    public init?(raw: [String: JSONValue], requestedLimit: Int = 50) {
        guard (1 ... 100).contains(requestedLimit), raw["scope"]?.stringValue == TaskPendingLaunchWire.scope,
              let observedAt = raw["observed_at"]?.stringValue, !observedAt.isEmpty,
              let values = raw["items"]?.arrayValue, values.count <= requestedLimit,
              let revision = raw["namespace_revision"]?.stringValue, TaskPendingLaunchWire.hex(revision, count: 64),
              let complete = raw["namespace_complete"]?.boolValue,
              let coverage = raw["coverage"]?.stringValue, !coverage.isEmpty,
              let invalid = raw["invalid_name_count"]?.wireIntegerValue, (0 ... 65536).contains(invalid),
              let examined = raw["examined_count"]?.wireIntegerValue, (0 ... 100).contains(examined), examined >= values.count,
              let more = raw["has_more"]?.boolValue,
              let cursor = TaskPendingLaunchWire.text(raw, "next_cursor", maximum: 4096),
              let bound = TaskPendingLaunchWire.text(raw, "bound", maximum: 1024),
              more ? (cursor?.isEmpty == false && examined > 0) : cursor == nil else { return nil }
        let items = values.compactMap { $0.objectValue.flatMap(TaskPendingLaunchItem.init(raw:)) }
        guard items.count == values.count, Set(items.map(\.taskID)).count == items.count,
              items.allSatisfy({ $0.disposition != .recorded && $0.disposition != .notFound }),
              coverage != "complete" || (complete && !more && invalid == 0 && bound == nil &&
                  items.allSatisfy { $0.disposition != .refused && $0.disposition != .unknown }) else { return nil }
        self.observedAt = observedAt
        self.items = items
        self.namespaceRevision = revision
        self.namespaceComplete = complete
        switch coverage {
        case "complete": self.coverage = .complete
        case "unknown": self.coverage = .unknown
        default: self.coverage = .unrecognized(coverage)
        }
        self.invalidNameCount = invalid
        self.examinedCount = examined
        self.hasMore = more
        self.nextCursor = cursor
        self.bound = bound
        self.raw = raw
    }
}
