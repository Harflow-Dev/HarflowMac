import Foundation

// MARK: - WorkflowSteeringEpisode

/// A held episode remains display evidence independently of current target churn.
public struct WorkflowSteeringEpisode: Equatable, Sendable {
    public let id: String
    public let revision: Int64
    public let state: String
    public let hold: Bool
    public let target: WorkflowSteeringTarget
    public let latestReplyReference: String?
    /// Public Unix timestamp in seconds; display evidence only, never local eligibility authority.
    public let createdAt: TimeInterval?

    init?(object: [String: Any], rootID: String) {
        guard let id = object["episode_id"] as? String, WorkflowSteeringWire.identifier(id),
              let revision = WorkflowSteeringWire.integer(object["steering_revision"]),
              let state = object["state"] as? String, !state.isEmpty,
              let hold = WorkflowSteeringWire.boolean(object["hold"]),
              let targetObject = object["target"] as? [String: Any],
              let target = WorkflowSteeringTarget(object: targetObject, rootID: rootID) else { return nil }
        let createdAt: TimeInterval?
        if let value = object["created_at"], !(value is NSNull) {
            guard WorkflowSteeringWire.boolean(value) == nil, let number = value as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            createdAt = number.doubleValue
        } else {
            createdAt = nil
        }
        self.id = id
        self.revision = revision
        self.state = state
        self.hold = hold
        self.target = target
        self.latestReplyReference = object["latest_reply_ref"] as? String
        self.createdAt = createdAt
    }
}

// MARK: - WorkflowSteeringStatus

/// One exact-root public status observation; global eligibility alone grants no root authority.
public struct WorkflowSteeringStatus: Equatable, Sendable {
    public let rootID: String
    public let productVersion: String
    public let schemaVersion: Int64
    public let ledgerEpoch: Int64?
    public let interactionEpoch: Int64
    public let controlRevision: Int64
    public let sequence: Int64
    /// Optional public compaction floor, independent of completeness and gap evidence.
    public let historyFloor: Int64?
    public let owner: String
    public let eligibleActions: Set<String>
    /// Explicit additive refusal codes; nil means the producer supplied no refusal-code evidence.
    public let refusalCodes: [String]?
    public let targets: [WorkflowSteeringTarget]
    public let episodes: [WorkflowSteeringEpisode]
    /// The complete canonical result, including additive display/control evidence.
    public let raw: Data

    /// Decodes one bounded ctl envelope, rejecting malformed fields and cross-root evidence.
    public init?(data: Data, rootID: String, productVersion: String = HarflowVersion.current) {
        guard WorkflowSteeringWire.identifier(rootID),
              let document = WorkflowSteeringWire.envelope(data, productVersion: productVersion),
              let writerVersion = document["product_version"] as? String,
              let object = document["result"] as? [String: Any],
              object["root_workflow_run_id"] as? String == rootID,
              WorkflowSteeringWire.integer(object["steering_version"]) == 1,
              let schema = WorkflowSteeringWire.integer(object["request_schema_version"]),
              let epoch = WorkflowSteeringWire.integer(object["interaction_epoch"]),
              let control = WorkflowSteeringWire.integer(object["control_revision"]),
              let sequence = WorkflowSteeringWire.integer(object["sequence"]),
              let owner = object["owner"] as? String,
              let actions = object["eligible_actions"] as? [String], Set(actions).count == actions.count,
              let targetObjects = object["targets"] as? [[String: Any]], targetObjects.count <= 4096,
              let episodeObjects = object["episodes"] as? [[String: Any]], episodeObjects.count <= 4096,
              let raw = WorkflowSteeringWire.canonical(object) else { return nil }
        let refusalCodes: [String]?
        if let refusals = object["refusals"], !(refusals is NSNull) {
            guard let rows = refusals as? [[String: Any]] else { return nil }
            let codes = rows.compactMap { $0["code"] as? String }
            guard codes.count == rows.count, codes.allSatisfy({ !$0.isEmpty }) else { return nil }
            refusalCodes = codes
        } else {
            refusalCodes = nil
        }
        let historyFloor: Int64?
        if let value = object["history_floor"], !(value is NSNull) {
            guard let floor = WorkflowSteeringWire.integer(value), floor <= sequence else { return nil }
            historyFloor = floor
        } else {
            historyFloor = nil
        }
        let ledger = WorkflowSteeringWire.integer(object["ledger_epoch"])
        guard schema != 2 || ledger != nil,
              object["ledger_epoch"] == nil || ledger != nil else { return nil }
        let targets = targetObjects.compactMap { WorkflowSteeringTarget(object: $0, rootID: rootID) }
        let episodes = episodeObjects.compactMap { WorkflowSteeringEpisode(object: $0, rootID: rootID) }
        guard targets.count == targetObjects.count, episodes.count == episodeObjects.count,
              Set(episodes.map(\.id)).count == episodes.count else { return nil }
        self.rootID = rootID
        self.productVersion = writerVersion
        self.schemaVersion = schema
        self.ledgerEpoch = ledger
        self.interactionEpoch = epoch
        self.controlRevision = control
        self.sequence = sequence
        self.historyFloor = historyFloor
        self.owner = owner
        self.eligibleActions = Set(actions)
        self.refusalCodes = refusalCodes
        self.targets = targets
        self.episodes = episodes
        self.raw = raw
    }

    /// A single current positive root target is required for open and retarget.
    public var rootTarget: WorkflowSteeringTarget? {
        let roots = targets.filter(\.isRootOrchestrator)
        return roots.count == 1 ? roots[0] : nil
    }

    /// Ambiguous or non-root held episodes never authorize root actions.
    public var heldRootEpisode: WorkflowSteeringEpisode? {
        let held = episodes.filter { $0.hold && $0.target.isRootOrchestrator }
        return held.count == 1 ? held[0] : nil
    }

    /// Checks local evidence only; the engine retains final CAS and eligibility authority.
    public func permits(_ action: WorkflowSteeringAction) -> Bool {
        guard [1, 2].contains(schemaVersion), eligibleActions.contains(action.rawValue) else { return false }
        switch action {
        case .open: return !episodes.contains(where: \.hold) && rootTarget != nil
        case .reply:
            guard let episode = heldRootEpisode, ["awaiting_caller", "command_refused"].contains(episode.state) else { return false }
            return targets.filter { $0 == episode.target }.count == 1
        case .retarget:
            guard let episode = heldRootEpisode else { return false }
            guard rootTarget != nil else { return false }
            let explicitlyStale = ["stale", "expired"].contains(episode.state)
            let replyUnavailable = ["awaiting_caller", "command_refused"].contains(episode.state) && !eligibleActions.contains("reply")
            return explicitlyStale || replyUnavailable
        case .dismiss:
            guard let episode = heldRootEpisode else { return false }
            return !["dismissing", "dismissed", "dismiss_pending_settlement"].contains(episode.state)
        }
    }
}
