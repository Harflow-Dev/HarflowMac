import Foundation

// MARK: - ResourceSlotOwner

/// Public owner identity. Unknown kinds retain their IDs without acquiring a navigation action.
public struct ResourceSlotOwner: Equatable, Hashable, Sendable {
    public let kind: String
    public let taskID: String?
    public let workflowRunID: String?
    public let activationID: String?

    public init(raw: [String: JSONValue]) throws {
        kind = try SlotWire.text(raw, "kind")
        taskID = try SlotWire.optionalOwnerIdentity(raw, "task_id")
        workflowRunID = try SlotWire.optionalOwnerIdentity(raw, "workflow_run_id")
        activationID = try SlotWire.optionalOwnerIdentity(raw, "activation_id")
    }

    /// Whether the current client understands this association.
    public var isKnown: Bool { ["task", "workflow_run", "workflow_attempt"].contains(kind) }

    /// Valid public task lookup syntax, independent of the resource owner's display evidence.
    public var metadataTaskID: String? {
        guard kind == "task", let taskID, SlotWire.matches(taskID, pattern: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$") else { return nil }
        return taskID
    }

    /// A workflow attempt requires both run and activation identity before offering a run association.
    public var metadataWorkflowRunID: String? {
        guard kind == "workflow_run" || kind == "workflow_attempt", let workflowRunID,
              SlotWire.matches(workflowRunID, pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$") else { return nil }
        if kind == "workflow_attempt" {
            guard let activationID, SlotWire.matches(activationID, pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$") else { return nil }
        }
        return workflowRunID
    }
}

// MARK: - ResourceReservation

/// One inventory reservation. Queue ordering is the containing public array's FIFO order.
public struct ResourceReservation: Equatable, Sendable {
    public let reservationID: String
    public let owner: ResourceSlotOwner
    public let generation: Int
    public let enqueuedAt: String
    public let grantedAt: String?
    public let deadlineAt: String?
    public let borrowsFrom: String?
    public let releaseRequested: Bool
    public let purpose: String?
    public let phaseState: String?
    public let diagnostic: String?
    public let leaseID: String?

    public init(raw: [String: JSONValue], held: Bool) throws {
        reservationID = try SlotWire.reservationIdentity(raw, "reservation_id")
        owner = try ResourceSlotOwner(raw: SlotWire.object(raw, "owner"))
        generation = try SlotWire.integer(raw, "generation", range: 1 ... Int.max)
        enqueuedAt = try SlotWire.timestamp(raw, "enqueued_at", required: true)!
        grantedAt = try SlotWire.timestamp(raw, "granted_at", required: held)
        deadlineAt = try SlotWire.timestamp(raw, "deadline_at")
        borrowsFrom = try SlotWire.optionalReservationIdentity(raw, "borrows_from")
        releaseRequested = try SlotWire.optionalBool(raw, "release_requested") ?? false
        purpose = try SlotWire.optionalText(raw, "purpose")
        phaseState = try SlotWire.optionalText(raw, "phase_state")
        diagnostic = try SlotWire.optionalText(raw, "diagnostic", limit: 16_384)
        leaseID = try SlotWire.optionalReservationIdentity(raw, "lease_id")
        if purpose == "phase", leaseID != reservationID { throw SlotWire.invalid("phase reservation identity") }
    }

    /// Borrowed holders are visible but consume no additional capacity.
    public var consumesCapacity: Bool { borrowsFrom == nil }
}

/// Inventory evidence from `harflow-ctl resources --json`.
public struct ResourceInventoryEntry: Equatable, Sendable {
    public let name: String
    public let capacity: Int
    public let holders: [ResourceReservation]
    public let queue: [ResourceReservation]

    public init(raw: [String: JSONValue]) throws {
        name = try SlotWire.name(raw, "name")
        capacity = try SlotWire.integer(raw, "capacity", range: 1 ... 4096)
        holders = try SlotWire.array(raw, "holders", maximum: 4096).map { try ResourceReservation(raw: SlotWire.row($0), held: true) }
        queue = try SlotWire.array(raw, "queue", maximum: 4096).map { try ResourceReservation(raw: SlotWire.row($0), held: false) }
        let ids = (holders + queue).map(\.reservationID)
        guard ids.count <= 4096, Set(ids).count == ids.count else { throw SlotWire.invalid("duplicate or excessive reservations") }
    }
}

// MARK: - PhaseSlotLease

/// Engine-projected blocker evidence, independent of the separately read inventory.
public struct PhaseSlotBlocker: Equatable, Sendable {
    public let reservationID: String
    public let owner: ResourceSlotOwner
    public let purpose: String
    public let state: String
    public let since: String?
    public let enqueuedAt: String?
    public let grantedAt: String?
    public let releaseRequested: Bool

    public init(raw: [String: JSONValue]) throws {
        reservationID = try SlotWire.reservationIdentity(raw, "reservation_id")
        owner = try ResourceSlotOwner(raw: SlotWire.object(raw, "owner"))
        purpose = try SlotWire.text(raw, "purpose")
        state = try SlotWire.text(raw, "state")
        since = try SlotWire.timestamp(raw, "since")
        enqueuedAt = try SlotWire.timestamp(raw, "enqueued_at")
        grantedAt = try SlotWire.timestamp(raw, "granted_at")
        releaseRequested = try SlotWire.optionalBool(raw, "release_requested") ?? false
    }
}

/// One phase observation. Historical receipts do not establish current occupancy.
public struct PhaseSlotLease: Equatable, Sendable {
    public let leaseID: String
    public let taskID: String
    public let name: String
    public let state: String
    public let capacity: Int
    public let position: Int?
    public let overcommitted: Bool?
    public let enqueuedAt: String
    public let grantedAt: String?
    public let deadlineAt: String?
    public let cleanupStartedAt: String?
    public let cleanupFinishedAt: String?
    public let diagnostic: String?
    public let blockedBy: [String]?
    public let blockers: [PhaseSlotBlocker]?

    public init(raw: [String: JSONValue]) throws {
        leaseID = try SlotWire.reservationIdentity(raw, "lease_id")
        taskID = try SlotWire.taskIdentity(raw, "task_id")
        name = try SlotWire.name(raw, "name")
        state = try SlotWire.text(raw, "state")
        capacity = try SlotWire.integer(raw, "capacity", range: 1 ... 4096)
        if raw["position"] == nil || raw["position"] == .null { position = nil } else { position = try SlotWire.integer(raw, "position", range: 1 ... 4096) }
        overcommitted = try SlotWire.optionalBool(raw, "overcommitted")
        enqueuedAt = try SlotWire.timestamp(raw, "enqueued_at", required: true)!
        grantedAt = try SlotWire.timestamp(raw, "granted_at")
        deadlineAt = try SlotWire.timestamp(raw, "deadline_at")
        cleanupStartedAt = try SlotWire.timestamp(raw, "cleanup_started_at")
        cleanupFinishedAt = try SlotWire.timestamp(raw, "cleanup_finished_at")
        diagnostic = try SlotWire.optionalText(raw, "diagnostic", limit: 16_384)
        if raw["blocked_by"] == nil || raw["blocked_by"] == .null { blockedBy = nil } else {
            let ids = try SlotWire.array(raw, "blocked_by", maximum: 100).map {
                try SlotWire.reservationIdentity(["id": $0], "id")
            }
            guard Set(ids).count == ids.count else { throw SlotWire.invalid("duplicate blocker IDs") }
            blockedBy = ids
        }
        if raw["blockers"] == nil || raw["blockers"] == .null { blockers = nil } else {
            let details = try SlotWire.array(raw, "blockers", maximum: 100).map { try PhaseSlotBlocker(raw: SlotWire.row($0)) }
            guard Set(details.map(\.reservationID)).count == details.count else { throw SlotWire.invalid("duplicate blocker details") }
            blockers = details
        }
        if let blockedBy, let blockers, Set(blockedBy) != Set(blockers.map(\.reservationID)) {
            throw SlotWire.invalid("blocker projection")
        }
    }

    /// A cap-sized projection may omit additional blockers; it does not prove truncation.
    public var blockersMayBeIncomplete: Bool { blockers?.count == 100 || blockedBy?.count == 100 }
    /// Missing additive blocker details remain unavailable, even if blocker IDs were supplied.
    public var blockerDetailsAvailable: Bool { blockers != nil && blockedBy != nil }
    /// Unknown future states are visible as unavailable detail, never as idle capacity.
    public var isKnownState: Bool {
        ["queued", "held", "cleanup_pending", "cleanup_running", "cleanup_failed", "cleanup_uncertain", "released", "expired", "resolved"].contains(state)
    }
}

// MARK: - PhaseSlotsStatus

/// Cleanup supervisor status, independent of snapshot freshness and resource occupancy.
public enum ResourceSlotServiceState: Equatable, Sendable {
    case alive, dead, missing, stopping, unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "alive": self = .alive
        case "dead": self = .dead
        case "missing": self = .missing
        case "stopping": self = .stopping
        default: self = .unknown(raw)
        }
    }
}

/// Aggregate public phase status. Events and private cleanup configuration are deliberately unused.
public struct PhaseSlotsStatus: Equatable, Sendable {
    public let leases: [PhaseSlotLease]
    public let truncated: Bool
    public let configurationEpoch: Int
    public let configuredCapacities: [String: Int]
    /// Qualified cleanup presence only; command arguments and executable identity are not retained.
    public let cleanupConfiguredNames: Set<String>
    /// Malformed cleanup presence remains unknown instead of being treated as disabled.
    public let cleanupPolicyUnavailableNames: Set<String>
    public let service: ResourceSlotServiceState

    public init(raw: [String: JSONValue]) throws {
        leases = try SlotWire.array(raw, "leases", maximum: 256).map { try PhaseSlotLease(raw: SlotWire.row($0)) }
        guard Set(leases.map(\.leaseID)).count == leases.count else { throw SlotWire.invalid("duplicate phase leases") }
        guard let truncated = raw["truncated"]?.boolValue else { throw SlotWire.invalid("truncated") }
        self.truncated = truncated
        let configuration = try SlotWire.object(raw, "configuration")
        configurationEpoch = try SlotWire.integer(configuration, "epoch", range: 0 ... Int.max)
        let names = try SlotWire.object(configuration, "names")
        guard names.count <= 256 else { throw SlotWire.invalid("configured names bound") }
        var capacities: [String: Int] = [:]
        var cleanupConfigured: Set<String> = []
        var cleanupUnavailable: Set<String> = []
        for (name, value) in names {
            _ = try SlotWire.name(["name": .string(name)], "name")
            let policy = try SlotWire.row(value)
            let capacity = try SlotWire.integer(policy, "capacity", range: 1 ... 4096)
            capacities[name] = capacity
            if let cleanup = policy["cleanup"], cleanup != .null {
                if capacity == 1, SlotWire.qualifiedCleanup(cleanup) { cleanupConfigured.insert(name) } else { cleanupUnavailable.insert(name) }
            }
        }
        configuredCapacities = capacities
        cleanupConfiguredNames = cleanupConfigured
        cleanupPolicyUnavailableNames = cleanupUnavailable
        service = ResourceSlotServiceState(try SlotWire.text(SlotWire.object(raw, "service"), "state"))
    }
}

// MARK: - TaskPhaseSlotsContext

/// Pure task-snapshot projection for the current conversation member; no additional polling.
public enum TaskPhaseSlotsContext: Equatable, Sendable {
    case hidden
    case leases([PhaseSlotLease])
    case unavailable(taskID: String, diagnostic: String)

    /// Absence and an empty array hide context. Minimal explicit unavailable rows need no lease fields.
    public static func decode(taskID: String, raw: [String: JSONValue]) -> TaskPhaseSlotsContext {
        guard let value = raw["phase_slots"] else { return .hidden }
        do {
            guard let rows = value.arrayValue, rows.count <= 1 else { throw SlotWire.invalid("task phase projection") }
            if rows.isEmpty { return .hidden }
            let row = try SlotWire.row(rows[0])
            guard try SlotWire.text(row, "task_id") == taskID else { throw SlotWire.invalid("task phase identity") }
            if try SlotWire.text(row, "state") == "unavailable" {
                return .unavailable(taskID: taskID, diagnostic: try SlotWire.text(row, "diagnostic", limit: 16_384))
            }
            return .leases([try PhaseSlotLease(raw: row)])
        } catch {
            return .unavailable(taskID: taskID, diagnostic: "Resource context is unavailable: malformed public task projection.")
        }
    }
}

// MARK: - SlotWire

/// Strict shared validation; additive object keys remain forward compatible.
enum SlotWire {
    static func invalid(_ field: String) -> ToolError {
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Malformed resource slots field: \(field)")
    }

    static func row(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let row = value.objectValue else { throw invalid("object") }
        return row
    }

    static func object(_ raw: [String: JSONValue], _ key: String) throws -> [String: JSONValue] {
        guard let object = raw[key]?.objectValue else { throw invalid(key) }
        return object
    }

    static func text(_ raw: [String: JSONValue], _ key: String, limit: Int = 256) throws -> String {
        guard let text = raw[key]?.stringValue, !text.isEmpty, text.count <= limit,
              !text.contains("\0") else { throw invalid(key) }
        return text
    }

    static func optionalText(_ raw: [String: JSONValue], _ key: String, limit: Int = 256) throws -> String? {
        guard let value = raw[key], value != .null else { return nil }
        guard let text = value.stringValue, text.count <= limit, !text.contains("\0") else { throw invalid(key) }
        return text
    }

    static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == (value.startIndex ..< value.endIndex)
    }

    static func reservationIdentity(_ raw: [String: JSONValue], _ key: String) throws -> String {
        let value = try text(raw, key, limit: 64)
        guard matches(value, pattern: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$") else { throw invalid(key) }
        return value
    }

    static func taskIdentity(_ raw: [String: JSONValue], _ key: String) throws -> String {
        try reservationIdentity(raw, key)
    }

    static func optionalReservationIdentity(_ raw: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = raw[key], value != .null else { return nil }
        return try reservationIdentity([key: value], key)
    }

    static func optionalOwnerIdentity(_ raw: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = raw[key], value != .null else { return nil }
        return try text([key: value], key, limit: 256)
    }

    static func name(_ raw: [String: JSONValue], _ key: String) throws -> String {
        let value = try text(raw, key, limit: 64)
        guard value.range(of: "^[a-z0-9][a-z0-9._:-]{0,63}$", options: .regularExpression) == (value.startIndex ..< value.endIndex) else { throw invalid(key) }
        return value
    }

    static func integer(_ raw: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = raw[key]?.wireIntegerValue, range.contains(value) else { throw invalid(key) }
        return value
    }

    static func optionalBool(_ raw: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = raw[key], value != .null else { return nil }
        guard let flag = value.boolValue else { throw invalid(key) }
        return flag
    }

    static func array(_ raw: [String: JSONValue], _ key: String, maximum: Int) throws -> [JSONValue] {
        guard let values = raw[key]?.arrayValue, values.count <= maximum else { throw invalid(key) }
        return values
    }

    static func qualifiedCleanup(_ value: JSONValue) -> Bool {
        guard let hook = value.objectValue, let timeout = hook["timeout_seconds"]?.wireIntegerValue,
              (1 ... 300).contains(timeout), validCleanupArguments(hook["argv"]),
              validCleanupExecutable(hook["executable"]) else { return false }
        return true
    }

    private static func validCleanupArguments(_ value: JSONValue?) -> Bool {
        guard let values = value?.arrayValue, (1 ... 32).contains(values.count) else { return false }
        let arguments = values.compactMap(\.stringValue)
        return arguments.count == values.count && arguments.allSatisfy { $0.unicodeScalars.count <= 4096 && !$0.contains("\0") }
            && arguments.reduce(0) { $0 + $1.unicodeScalars.count } <= 16_384 && arguments[0].hasPrefix("/")
    }

    private static func validCleanupExecutable(_ value: JSONValue?) -> Bool {
        guard let fields = value?.objectValue, let digest = fields["sha256"]?.stringValue,
              matches(digest, pattern: "^[a-f0-9]{64}$") else { return false }
        return ["device", "inode", "size", "mtime_ns"].allSatisfy { key in
            guard let value = fields[key], case .number(let number, isInteger: true) = value else { return false }
            return number.isFinite && number >= 0
        }
    }

    static func timestamp(_ raw: [String: JSONValue], _ key: String, required: Bool = false) throws -> String? {
        let value = try optionalText(raw, key)
        guard !required || value != nil else { throw invalid(key) }
        if let value, ISODate.parse(value) == nil { throw invalid(key) }
        return value
    }
}
