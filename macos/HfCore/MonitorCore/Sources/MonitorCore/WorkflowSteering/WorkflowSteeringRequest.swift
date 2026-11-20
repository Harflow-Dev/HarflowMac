import Foundation

// MARK: - WorkflowSteeringAction

/// Explicit root actions supported by the native public adapter.
public enum WorkflowSteeringAction: String, Equatable, Sendable {
    case open, reply, retarget, dismiss
}

// MARK: - WorkflowSteeringRequest

/// An immutable request derived from the exact displayed root status, never a replacement target.
public struct WorkflowSteeringRequest: Equatable, Sendable {
    public let status: WorkflowSteeringStatus
    public let action: WorkflowSteeringAction
    public let text: String?
    public let requestID: String
    public let episodeID: String?
    public let data: Data

    /// Validates root authority, text and both native and producer serialized request bounds.
    public init(status: WorkflowSteeringStatus, action: WorkflowSteeringAction, text: String? = nil, requestID: UUID = UUID()) throws {
        guard status.permits(action) else { throw WorkflowSteeringWire.error("Root steering action is unavailable for this observation") }
        if action == .dismiss {
            guard text == nil else { throw WorkflowSteeringWire.error("Dismiss cannot contain text") }
        } else {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32768 else {
                throw WorkflowSteeringWire.error("Steering text is blank or exceeds 32 KiB UTF-8")
            }
        }
        let episode = action == .open ? nil : status.heldRootEpisode
        let target: WorkflowSteeringTarget?
        switch action {
        case .open, .retarget: target = status.rootTarget
        case .reply, .dismiss: target = episode?.target
        }
        guard let target, let targetObject = WorkflowSteeringWire.object(target.raw) else {
            throw WorkflowSteeringWire.error("Missing exact root target")
        }
        let id = requestID.uuidString.lowercased()
        var object: [String: Any] = [
            "schema_version": status.schemaVersion, "request_id": id, "action": action.rawValue,
            "expected_interaction_epoch": status.interactionEpoch, "expected_control_revision": status.controlRevision,
            "episode_id": episode?.id as Any? ?? NSNull(), "expected_steering_revision": episode?.revision as Any? ?? NSNull(),
            "target": targetObject
        ]
        if status.schemaVersion == 2 { object["ledger_epoch"] = status.ledgerEpoch }
        if action != .dismiss {
            object["text"] = text
            object["allow_fresh_context"] = false
        }
        if action == .retarget { object["supersedes_episode_id"] = episode?.id }
        guard let data = WorkflowSteeringWire.canonical(object), data.count <= WorkflowSteeringWire.maximumRequestBytes,
              Self.producerSerializedBytes(data) <= WorkflowSteeringWire.maximumRequestBytes else {
            throw WorkflowSteeringWire.error("Steering request exceeds 128 KiB serialized limit")
        }
        self.status = status
        self.action = action
        self.text = text
        self.requestID = id
        self.episodeID = episode?.id
        self.data = data
    }

    // Python's default ensure_ascii expands DEL and each non-ASCII UTF-16 unit to six ASCII bytes.
    // Native compact JSON plus the producer's default separator spaces gives a safe upper bound.
    private static func producerSerializedBytes(_ data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return .max }
        var bytes = 0
        var inString = false
        var escaped = false
        for unit in text.utf16 {
            bytes += unit < 127 ? 1 : 6
            if inString {
                if escaped {
                    escaped = false
                } else if unit == 92 {
                    escaped = true
                } else if unit == 34 {
                    inString = false
                }
            } else if unit == 34 {
                inString = true
            } else if unit == 44 || unit == 58 {
                bytes += 1
            }
        }
        return bytes
    }
}

// MARK: - WorkflowSteeringReceipt

/// Positive admission only; scheduled and state remain independent lifecycle evidence.
public struct WorkflowSteeringReceipt: Equatable, Sendable {
    public let requestID: String
    public let episodeID: String
    public let steeringRevision: Int64
    public let interactionEpoch: Int64
    public let controlRevision: Int64
    public let ledgerEpoch: Int64?
    public let sequence: Int64
    public let scheduled: Bool
    public let replayed: Bool
    public let state: String
    public let raw: Data

    /// Validates a receipt against the immutable original request and its epochs.
    public init?(data: Data, matching request: WorkflowSteeringRequest, productVersion: String = HarflowVersion.current) {
        guard let document = WorkflowSteeringWire.envelope(data, productVersion: productVersion), let object = document["result"] as? [String: Any],
              WorkflowSteeringWire.boolean(object["accepted"]) == true,
              object["request_id"] as? String == request.requestID,
              let episode = object["episode_id"] as? String, WorkflowSteeringWire.identifier(episode),
              let revision = WorkflowSteeringWire.integer(object["steering_revision"]),
              let interaction = WorkflowSteeringWire.integer(object["interaction_epoch"]), interaction == request.status.interactionEpoch,
              let control = WorkflowSteeringWire.integer(object["control_revision"]), control >= request.status.controlRevision,
              let sequence = WorkflowSteeringWire.integer(object["sequence"]), sequence > request.status.sequence,
              let scheduled = WorkflowSteeringWire.boolean(object["scheduled"]),
              let replayed = WorkflowSteeringWire.boolean(object["replayed"]),
              let state = object["state"] as? String, !state.isEmpty,
              let raw = WorkflowSteeringWire.canonical(object) else { return nil }
        let ledger = WorkflowSteeringWire.integer(object["ledger_epoch"])
        guard request.status.schemaVersion != 2 || ledger == request.status.ledgerEpoch else { return nil }
        switch request.action {
        case .reply, .dismiss: guard episode == request.episodeID else { return nil }
        case .open, .retarget: guard !request.status.episodes.contains(where: { $0.id == episode }) else { return nil }
        }
        self.requestID = request.requestID
        self.episodeID = episode
        self.steeringRevision = revision
        self.interactionEpoch = interaction
        self.controlRevision = control
        self.ledgerEpoch = ledger
        self.sequence = sequence
        self.scheduled = scheduled
        self.replayed = replayed
        self.state = state
        self.raw = raw
    }
}
