import Foundation

// MARK: - WorkflowSteeringHistoryItem

/// Ordered public history evidence, including unsupported future kinds without interpretation.
public struct WorkflowSteeringHistoryItem: Equatable, Sendable {
    public let sequence: Int64
    public let kind: String
    public let action: String?
    public let requestID: String?
    public let episodeID: String?
    public let turnID: String?
    public let outcome: String?
    public let text: String?
    public let raw: Data

    init?(object: [String: Any]) {
        guard let sequence = WorkflowSteeringWire.integer(object["sequence"]), sequence > 0,
              let kind = object["kind"] as? String, !kind.isEmpty,
              let raw = WorkflowSteeringWire.canonical(object) else { return nil }
        for key in ["action", "request_id", "episode_id", "turn_id", "outcome", "text"] {
            guard object[key] == nil || object[key] is NSNull || object[key] is String else { return nil }
        }
        if let id = object["request_id"] as? String, !WorkflowSteeringWire.uuid(id) { return nil }
        for key in ["episode_id", "turn_id"] {
            if let id = object[key] as? String, !WorkflowSteeringWire.identifier(id) { return nil }
        }
        self.sequence = sequence
        self.kind = kind
        self.action = object["action"] as? String
        self.requestID = object["request_id"] as? String
        self.episodeID = object["episode_id"] as? String
        self.turnID = object["turn_id"] as? String
        self.outcome = object["outcome"] as? String
        self.text = object["text"] as? String
        self.raw = raw
    }
}

// MARK: - WorkflowSteeringHistoryPage

/// One bounded exact-root page. Gaps or absence never prove nonadmission.
public struct WorkflowSteeringHistoryPage: Equatable, Sendable {
    public let rootID: String
    public let productVersion: String
    public let items: [WorkflowSteeringHistoryItem]
    public let nextCursor: String?
    public let hasMore: Bool
    public let gap: Bool
    public let historyIncomplete: Bool
    public let raw: Data

    /// Decodes strictly ordered row identities and explicit cursor/completeness metadata.
    public init?(data: Data, rootID: String, productVersion: String = HarflowVersion.current) {
        guard WorkflowSteeringWire.identifier(rootID), let document = WorkflowSteeringWire.envelope(data, productVersion: productVersion),
              let writerVersion = document["product_version"] as? String,
              let object = document["result"] as? [String: Any], object["root_workflow_run_id"] as? String == rootID,
              let rows = object["items"] as? [[String: Any]], rows.count <= 50,
              let more = WorkflowSteeringWire.boolean(object["has_more"]),
              let gap = WorkflowSteeringWire.boolean(object["gap"]),
              let incomplete = WorkflowSteeringWire.boolean(object["history_incomplete"]),
              let raw = WorkflowSteeringWire.canonical(object) else { return nil }
        let cursor = object["next_cursor"] as? String
        guard object["next_cursor"] is NSNull || cursor != nil,
              cursor.map({ $0.utf8.count <= 4096 && WorkflowSteeringWire.cursorSequence($0, rootID: rootID) != nil }) ?? true,
              more == (cursor != nil) else { return nil }
        let items = rows.compactMap(WorkflowSteeringHistoryItem.init)
        guard items.count == rows.count,
              cursor.map({ WorkflowSteeringWire.cursorSequence($0, rootID: rootID) == items.last?.sequence }) ?? true,
              zip(items, items.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else { return nil }
        self.rootID = rootID
        self.productVersion = writerVersion
        self.items = items
        self.nextCursor = cursor
        self.hasMore = more
        self.gap = gap
        self.historyIncomplete = incomplete
        self.raw = raw
    }

    /// Continues after the last item actually read within a captured status sequence horizon.
    /// A missing eligible item returns nil rather than inventing a cursor at the supplied horizon.
    public func continuationCursor(atOrBefore horizon: Int64) -> String? {
        guard let item = items.last(where: { $0.sequence <= horizon }) else { return nil }
        return "\(rootID):\(item.sequence)"
    }

    /// Exact later requested rows prove admission only, independently of unrelated pruned rows.
    public func admissionEvidence(for request: WorkflowSteeringRequest, status: WorkflowSteeringStatus) -> WorkflowSteeringHistoryItem? {
        guard rootID == request.status.rootID, status.rootID == rootID,
              [1, 2].contains(status.schemaVersion), status.sequence >= request.status.sequence else { return nil }
        let matching = items.filter { row in
            guard row.sequence > request.status.sequence, row.sequence <= status.sequence,
                  row.kind == "requested", row.requestID == request.requestID,
                  row.action == request.action.rawValue, Self.verbatimTextMatches(row.text, request.text), let episode = row.episodeID else { return false }
            switch request.action {
            case .reply, .dismiss: return episode == request.episodeID
            case .open, .retarget:
                guard !request.status.episodes.contains(where: { $0.id == episode }) else { return false }
                let retained = status.episodes.filter { $0.id == episode }
                return retained.isEmpty || retained.count == 1 && retained[0].target.isRootOrchestrator
            }
        }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func verbatimTextMatches(_ observed: String?, _ requested: String?) -> Bool {
        switch (observed, requested) {
        case (nil, nil): return true
        case (.some(let observed), .some(let requested)): return observed.utf8.elementsEqual(requested.utf8)
        default: return false
        }
    }

}
