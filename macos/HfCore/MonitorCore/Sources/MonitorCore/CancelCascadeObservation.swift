import Foundation

// MARK: - CancelCascadeObservation

/// Read-only `task-cancel-cascade.v1` account of what a cancel left behind. Not edited into `CascadeSummary`.
public struct CancelCascadeObservation: Equatable, Sendable {
    /// The engine documents at most 100 rows.
    public static let maximumRows = 100

    public enum Coverage: Equatable, Sendable {
        case complete, incomplete
        /// The engine reported `unknown` (including its minimal fallback).
        case unknown
        case unrecognized(String)

        init(_ raw: String) {
            switch raw {
            case "complete": self = .complete
            case "incomplete": self = .incomplete
            case "unknown": self = .unknown
            default: self = .unrecognized(raw)
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case stopped, running
            case unknown
            case unrecognized(String)

            init(_ raw: String) {
                switch raw {
                case "stopped": self = .stopped
                case "running": self = .running
                case "unknown": self = .unknown
                default: self = .unrecognized(raw)
                }
            }
        }

        public enum Basis: Equatable, Sendable {
            case observedSettlement, confirmedLiveIdentity, provenNotStarted, insufficientEvidence
            case unrecognized(String)

            init(_ raw: String) {
                switch raw {
                case "observed_settlement": self = .observedSettlement
                case "confirmed_live_identity": self = .confirmedLiveIdentity
                case "proven_not_started": self = .provenNotStarted
                case "insufficient_evidence": self = .insufficientEvidence
                default: self = .unrecognized(raw)
                }
            }
        }

        public let taskID: String
        public let state: State
        public let basis: Basis
        /// Qualified resolved status text, or nil; never inferred from `state`.
        public let status: String?

        init?(raw: [String: JSONValue]) {
            guard let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty,
                  let state = raw["state"]?.stringValue, let basis = raw["basis"]?.stringValue,
                  let status = WireFields.nullableString(raw, "status") else { return nil }
            self.taskID = taskID
            self.state = State(state)
            self.basis = Basis(basis)
            self.status = status
        }
    }

    public let scope: String
    public let observedAt: String
    public let coverage: Coverage
    /// Separate from coverage: rows were omitted by the engine's row or byte bound.
    public let truncated: Bool
    public let items: [Item]

    /// More than `maximumRows` rows, or any damaged row, makes the whole observation malformed.
    public init?(raw: [String: JSONValue]) {
        guard let scope = raw["scope"]?.stringValue, let observedAt = raw["observed_at"]?.stringValue, !observedAt.isEmpty,
              let coverage = raw["coverage"]?.stringValue, let truncated = raw["truncated"]?.boolValue,
              let values = raw["items"]?.arrayValue, values.count <= Self.maximumRows else { return nil }
        let items = values.compactMap { $0.objectValue.flatMap(Item.init(raw:)) }
        guard items.count == values.count else { return nil }
        self.scope = scope
        self.observedAt = observedAt
        self.coverage = Coverage(coverage)
        self.truncated = truncated
        self.items = items
    }

    /// Callers must require `task-cancel-cascade.v1` on a fresh handshake before trusting this field;
    /// no code gate exists yet because nothing consumes it.
    ///
    /// Reads `cascade.observation` of a successful cancel result. A missing or non-object `cascade`
    /// (an older engine) is `absent`, like the legacy summary treats it.
    public static func reading(in result: [String: JSONValue]) -> WireObservation<CancelCascadeObservation> {
        guard let cascade = result["cascade"]?.objectValue, let value = cascade["observation"] else { return .absent }
        guard let object = value.objectValue, let observation = CancelCascadeObservation(raw: object) else { return .malformed }
        return .present(observation)
    }
}
