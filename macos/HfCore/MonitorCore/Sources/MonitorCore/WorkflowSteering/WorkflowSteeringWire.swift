import CoreFoundation
import Foundation

// MARK: - WorkflowSteeringWire

/// Bounded exact-integer JSON decoding shared by the steering adapters.
enum WorkflowSteeringWire {
    static let maximumDocumentBytes = 1 << 20
    static let maximumRequestBytes = 128 << 10

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let result = Int64(number.stringValue), result >= 0 else { return nil }
        return result
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func identifier(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static func cursorSequence(_ value: String, rootID: String) -> Int64? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == rootID, !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let sequence = Int64(parts[1]), sequence >= 0 else { return nil }
        return sequence
    }

    static func uuid(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    static func canonical(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= maximumDocumentBytes else { return nil }
        var keys = SteeringJSONKeys(bytes: Array(data))
        guard keys.validate(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func envelope(_ data: Data, productVersion: String = HarflowVersion.current) -> [String: Any]? {
        guard let raw = object(data), raw["product"] as? String == "harflow", raw["format"] as? String == "harflow.ctl",
              integer(raw["v"]) == 1,
              let version = raw["product_version"] as? String, let writer = HarflowVersion(version),
              let consumer = HarflowVersion(productVersion), writer.isCompatible(with: consumer),
              ["result", "error", "unknown"].filter({ raw[$0] != nil }).count == 1 else { return nil }
        return raw
    }

    static func error(_ detail: String) -> ToolError {
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: detail)
    }
}

// MARK: - WorkflowSteeringTarget

/// Complete engine-issued target, preserved without a floating-point JSON projection.
public struct WorkflowSteeringTarget: Equatable, Sendable {
    /// Canonical JSON retains nulls, additive fields and exact integer tokens.
    public let raw: Data
    public let rootID: String
    public let runID: String
    public let path: [String]
    public let role: String

    init?(object: [String: Any], rootID: String) {
        guard object["root_workflow_run_id"] as? String == rootID,
              let run = object["workflow_run_id"] as? String, WorkflowSteeringWire.identifier(run),
              let path = object["path"] as? [String], !path.isEmpty, path.count <= 64,
              path.first == rootID, path.last == run, Set(path).count == path.count,
              path.allSatisfy(WorkflowSteeringWire.identifier),
              let role = object["role"] as? String, !role.isEmpty,
              let raw = WorkflowSteeringWire.canonical(object) else { return nil }
        for key in ["checkpoint_revision", "goal_revision", "interaction_epoch", "control_revision"] {
            guard WorkflowSteeringWire.integer(object[key]) != nil else { return nil }
        }
        for key in ["assignment_revision", "draft_revision", "source_revision"] {
            guard object[key] is NSNull || WorkflowSteeringWire.integer(object[key]) != nil else { return nil }
        }
        for key in ["activation_id", "assignment_digest", "decision_id", "definition_digest", "node_id", "preview_hash",
                    "source_definition_digest", "source_workflow_id", "task_id", "token_id"] {
            guard object[key] is NSNull || object[key] is String else { return nil }
        }
        self.raw = raw
        self.rootID = rootID
        self.runID = run
        self.path = path
        self.role = role
    }

    /// Only this shape is admitted by the first native steering slice.
    public var isRootOrchestrator: Bool { role == "orchestrator" && runID == rootID && path == [rootID] }
}

// MARK: - SteeringJSONKeys

/// Rejects duplicate decoded object keys before Foundation can collapse their values.
private struct SteeringJSONKeys {
    let bytes: [UInt8]
    var index = 0

    mutating func validate() -> Bool {
        guard value(depth: 0) else { return false }
        whitespace()
        return index == bytes.count
    }

    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func string() -> String? {
        whitespace()
        let start = index
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 {
                guard index < bytes.count else { return nil }
                index += 1
            } else if byte == 34 {
                return (try? JSONSerialization.jsonObject(with: Data(bytes[start ..< index]), options: [.fragmentsAllowed])) as? String
            }
        }
        return nil
    }

    mutating func object(depth: Int) -> Bool {
        index += 1
        if consume(125) { return true }
        var keys = Set<String>()
        repeat {
            guard let key = string(), keys.insert(key).inserted, consume(58), value(depth: depth + 1) else { return false }
            if consume(125) { return true }
        } while consume(44)
        return false
    }

    mutating func array(depth: Int) -> Bool {
        index += 1
        if consume(93) { return true }
        repeat {
            guard value(depth: depth + 1) else { return false }
            if consume(93) { return true }
        } while consume(44)
        return false
    }

    mutating func value(depth: Int) -> Bool {
        whitespace()
        guard depth < 128, index < bytes.count else { return false }
        switch bytes[index] {
        case 123: return object(depth: depth)
        case 91: return array(depth: depth)
        case 34: return string() != nil
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            return index > start
        }
    }
}
