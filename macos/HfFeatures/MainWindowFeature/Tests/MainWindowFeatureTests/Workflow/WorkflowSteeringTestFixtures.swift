import Foundation
import MonitorCore

/// Synthetic public wire data for presentation and hosted tests. These fixtures are deliberately
/// feature-local and are not vendored contract evidence or qualification of a real runtime.
enum WorkflowSteeringTestFixtures {
    static let rootRunID = String(repeating: "a", count: 32)
    static let workerID = String(repeating: "b", count: 32)
    static let episodeID = String(repeating: "c", count: 32)
    static let turnID = String(repeating: "d", count: 32)

    static func status(
        rootID: String = WorkflowSteeringTestFixtures.rootRunID,
        schema: Int = 2,
        sequence: Int = 10,
        state: String? = nil,
        held: Bool = false,
        role: String = "orchestrator",
        eligibleActions: [String] = ["open"],
        createdAt: Double? = 1_793_836_800,
        latestReplyReference: String? = nil,
        refusalCodes: [String]? = []
    ) throws -> WorkflowSteeringStatus {
        let target = target(rootID: rootID, role: role)
        var result: [String: Any] = [
            "root_workflow_run_id": rootID,
            "steering_version": 1,
            "request_schema_version": schema,
            "ledger_epoch": 1,
            "interaction_epoch": 1,
            "control_revision": 1,
            "sequence": sequence,
            "history_floor": 1,
            "owner": "monitor",
            "eligible_actions": eligibleActions,
            "targets": [target],
            // swiftformat:disable:next trailingCommas
            "episodes": [] as [[String: Any]]
        ]
        if schema == 1 { result.removeValue(forKey: "ledger_epoch") }
        if let refusalCodes {
            result["refusals"] = refusalCodes.map { ["code": $0] }
        }
        if let state {
            var episode: [String: Any] = [
                "episode_id": episodeID,
                "steering_revision": 1,
                "state": state,
                "hold": held,
                "target": target,
                "latest_reply_ref": latestReplyReference.map { $0 as Any } ?? NSNull(),
                // swiftformat:disable:next trailingCommas
                "created_at": createdAt.map { $0 as Any } ?? NSNull()
            ]
            if latestReplyReference == nil { episode.removeValue(forKey: "latest_reply_ref") }
            result["episodes"] = [episode]
        }
        let data = try envelope(result)
        guard let decoded = WorkflowSteeringStatus(data: data, rootID: rootID) else {
            throw FixtureError.invalidStatus
        }
        return decoded
    }

    static func history(
        rootID: String = WorkflowSteeringTestFixtures.rootRunID,
        items: [[String: Any]],
        nextCursor: String? = nil,
        gap: Bool = false,
        incomplete: Bool = false
    ) throws -> WorkflowSteeringHistoryPage {
        let result: [String: Any] = [
            "root_workflow_run_id": rootID,
            "items": items,
            "has_more": nextCursor != nil,
            "next_cursor": nextCursor.map { $0 as Any } ?? NSNull(),
            "gap": gap,
            // swiftformat:disable:next trailingCommas
            "history_incomplete": incomplete
        ]
        guard let decoded = WorkflowSteeringHistoryPage(data: try envelope(result), rootID: rootID) else {
            throw FixtureError.invalidHistory
        }
        return decoded
    }

    static func ctlEnvelope(resultData: Data) throws -> Data {
        guard let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw FixtureError.invalidEnvelope
        }
        return try envelope(result)
    }

    static func historyItem(
        sequence: Int,
        kind: String,
        action: String? = nil,
        requestID: String? = nil,
        episodeID: String? = nil,
        turnID: String? = nil,
        outcome: String? = nil,
        text: String? = nil
    ) -> [String: Any] {
        var item: [String: Any] = ["sequence": sequence, "kind": kind]
        for (key, value) in [
            ("action", action), ("request_id", requestID), ("episode_id", episodeID),
            // swiftformat:disable:next trailingCommas
            ("turn_id", turnID), ("outcome", outcome), ("text", text)
        ] {
            if let value { item[key] = value }
        }
        return item
    }

    private static func target(rootID: String, role: String) -> [String: Any] {
        [
            "root_workflow_run_id": rootID,
            "workflow_run_id": rootID,
            "path": [rootID],
            "role": role,
            "checkpoint_revision": 1,
            "goal_revision": 1,
            "interaction_epoch": 1,
            "control_revision": 1,
            "assignment_revision": NSNull(),
            "draft_revision": NSNull(),
            "source_revision": NSNull(),
            "activation_id": NSNull(),
            "assignment_digest": NSNull(),
            "decision_id": NSNull(),
            "definition_digest": NSNull(),
            "node_id": NSNull(),
            "preview_hash": NSNull(),
            "source_definition_digest": NSNull(),
            "source_workflow_id": NSNull(),
            "task_id": NSNull(),
            // swiftformat:disable:next trailingCommas
            "token_id": NSNull()
        ]
    }

    private static func envelope(_ result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "product": "harflow",
            "format": "harflow.ctl",
            "v": 1,
            "product_version": HarflowVersion.current,
            // swiftformat:disable:next trailingCommas
            "result": result
        ], options: [.sortedKeys])
    }

    private enum FixtureError: Error {
        case invalidStatus
        case invalidHistory
        case invalidEnvelope
    }
}
