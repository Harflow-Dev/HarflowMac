import Foundation

// MARK: - ContinuationStop

/// Advisory `task-continuation-stop.v1` observation on task status. It never grants eligibility.
public struct ContinuationStop: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case stopped, notStopped
        /// The engine reported `unknown`: the marker could not be read safely.
        case unknown
        /// A value this app does not know.
        case unrecognized(String)

        init(_ raw: String) {
            switch raw {
            case "stopped": self = .stopped
            case "not_stopped": self = .notStopped
            case "unknown": self = .unknown
            default: self = .unrecognized(raw)
            }
        }
    }

    public enum Reason: Equatable, Sendable {
        case chainCancelled
        case unrecognized(String)

        init(_ raw: String) { self = raw == "chain_cancelled" ? .chainCancelled : .unrecognized(raw) }
    }

    public let state: State
    /// Null when the selected identity is invalid.
    public let chainRootTaskID: String?
    /// Non-null only for a stopped chain.
    public let reason: Reason?
    /// Syntactic marker attribution, not verified authorship.
    public let cancelledTaskID: String?
    /// Reader-generated time, not the cancellation time.
    public let observedAt: String

    /// Requires all five keys; the three nullable ones must be a string or an explicit null.
    public init?(raw: [String: JSONValue]) {
        guard let state = raw["state"]?.stringValue,
              let root = WireFields.nullableString(raw, "chain_root_task_id"),
              let reason = WireFields.nullableString(raw, "reason"),
              let cancelled = WireFields.nullableString(raw, "cancelled_task_id"),
              let observedAt = raw["observed_at"]?.stringValue, !observedAt.isEmpty else { return nil }
        self.state = State(state)
        chainRootTaskID = root
        self.reason = reason.map(Reason.init)
        cancelledTaskID = cancelled
        self.observedAt = observedAt
    }

    /// Reads the object under `continuation_stop` of a status payload.
    public static func reading(in task: [String: JSONValue]) -> WireObservation<ContinuationStop> {
        guard let value = task["continuation_stop"] else { return .absent }
        guard let object = value.objectValue, let stop = ContinuationStop(raw: object) else { return .malformed }
        return .present(stop)
    }
}

public extension TaskInfo {
    /// Continuation-stop observation from full, brief and batch status rows; `absent` on older engines.
    /// Callers must require `task-continuation-stop.v1` on a fresh handshake before trusting this
    /// field. It is advisory and never grants eligibility; no code gate exists yet because nothing consumes it.
    var continuationStop: WireObservation<ContinuationStop> { ContinuationStop.reading(in: raw) }
}

// MARK: - ChainStoppedRefusal

/// The typed `start_failed` refusal for a continuation whose chain was cancelled.
public struct ChainStoppedRefusal: Equatable, Sendable {
    public let chainRootTaskID: String
}

public extension ToolError {
    /// Non-nil only for a `start_failed` refusal whose `data.reason` is `chain_stopped` with a root ID.
    /// Display text is never parsed.
    var chainStopped: ChainStoppedRefusal? {
        guard case .structuredRefusal(let code, _, let data) = self, code == "start_failed",
              data["reason"]?.stringValue == "chain_stopped",
              let root = data["chain_root_task_id"]?.stringValue, !root.isEmpty else { return nil }
        return ChainStoppedRefusal(chainRootTaskID: root)
    }
}
