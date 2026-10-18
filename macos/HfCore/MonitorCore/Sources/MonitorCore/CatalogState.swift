import Foundation

// MARK: - CatalogState

/// Structured readiness of an authoritative catalog read, with legacy response compatibility.
public struct CatalogState: Equatable, Sendable {
    /// Whether authority is available, temporarily preparing, or persistently blocked.
    public enum Status: String, Sendable { case ready, preparing, blocked }
    public let status: Status
    public let source: String
    public let reason: String?
    public let pendingRecords: Int
    public let blockedRecords: Int
    public var isReady: Bool { status == .ready }

    public init(raw: [String: JSONValue]) {
        let state = raw["catalog_state"]?.objectValue ?? [:]
        status = state["status"]?.stringValue.flatMap(Status.init(rawValue:))
            ?? (raw["authority_incomplete"]?.boolValue == true ? .blocked : raw["bootstrap_pending"]?.boolValue == true ? .preparing : .ready)
        source = state["source"]?.stringValue ?? "catalog"
        reason = state["reason"]?.stringValue
        pendingRecords = max(0, state["pending_records"]?.intValue ?? 0)
        blockedRecords = max(0, state["blocked_records"]?.intValue ?? 0)
    }
}
