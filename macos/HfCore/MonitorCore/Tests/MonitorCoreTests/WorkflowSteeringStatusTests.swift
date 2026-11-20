import Foundation
@testable import MonitorCore
import Testing

struct WorkflowSteeringStatusTests {
    private let root = String(repeating: "a", count: 32)
    private let child = String(repeating: "b", count: 32)
    private let episodeID = String(repeating: "c", count: 32)

    @Test(arguments: [Int64(1), Int64(2)])
    func givenSupportedSchema_whenDecodingStatus_thenPreservesRootSequenceAndRawTarget(schema: Int64) throws {
        let data = try status(schema: schema, sequence: 9, targets: [target(run: root, role: "orchestrator", path: [root])])
        let decoded = try #require(WorkflowSteeringStatus(data: data, rootID: root))

        #expect(decoded.schemaVersion == schema)
        #expect(decoded.sequence == 9)
        #expect(decoded.ledgerEpoch == (schema == 2 ? 7 : nil))
        #expect(decoded.refusalCodes == nil)
        #expect(decoded.rootTarget?.isRootOrchestrator == true)
        let target = try #require(decoded.rootTarget)
        let rawTarget = try #require(String(bytes: target.raw, encoding: .utf8))
        #expect(rawTarget.contains("future_field"))
    }

    @Test(arguments: ["wrong root", "floating sequence", "boolean sequence", "missing schema 2 ledger", "duplicate episode", "duplicate key"])
    func givenMalformedOrCrossRootStatus_whenDecoding_thenRejectsWholeObservation(caseName: String) throws {
        let data: Data = switch caseName {
        case "wrong root": try status(schema: 1, rootID: child)
        case "floating sequence": try statusWithRawSequence("1.0")
        case "boolean sequence": try status(schema: 1, sequenceToken: true)
        case "missing schema 2 ledger": try status(schema: 2, includeLedger: false)
        case "duplicate episode": try status(schema: 1, episodes: [episode(state: "pending"), episode(state: "pending")])
        default: try statusWithDuplicateSequenceKey()
        }
        #expect(WorkflowSteeringStatus(data: data, rootID: root) == nil)
    }

    @Test func givenRootAndChildHeldEpisodes_whenSelectingHold_thenOnlyUniqueRootEpisodeIsReturned() throws {
        let rootEpisode = episode(state: "pending", targetRun: root, targetRole: "orchestrator", targetPath: [root])
        let childEpisode = episode(id: child, state: "pending", targetRun: child, targetRole: "builder", targetPath: [root, child])
        let decoded = try #require(WorkflowSteeringStatus(data: status(schema: 2,
            targets: [target(run: root, role: "orchestrator", path: [root])], episodes: [rootEpisode, childEpisode]), rootID: root))
        #expect(decoded.heldRootEpisode?.id == episodeID)
    }

    private func status(schema: Int64, rootID: String? = nil, sequence: Int64 = 4,
                        sequenceToken: Any? = nil, includeLedger: Bool = true,
                        targets: [[String: Any]] = [], episodes: [[String: Any]] = []) throws -> Data {
        let actualRoot = rootID ?? root
        var result: [String: Any] = [
            "root_workflow_run_id": actualRoot, "steering_version": 1, "request_schema_version": schema,
            "interaction_epoch": 2, "control_revision": 3, "sequence": sequenceToken ?? sequence,
            "owner": "monitor", "eligible_actions": ["open", "reply", "retarget", "dismiss"],
            "targets": targets, "episodes": episodes
        ]
        if schema == 2, includeLedger { result["ledger_epoch"] = 7 }
        return try envelope(["result": result])
    }

    private func target(run: String, role: String, path: [String]) -> [String: Any] {
        ["root_workflow_run_id": root, "workflow_run_id": run, "path": path, "role": role,
         "checkpoint_revision": 1, "goal_revision": 1, "interaction_epoch": 2, "control_revision": 3,
         "assignment_revision": NSNull(), "draft_revision": NSNull(), "source_revision": NSNull(),
         "activation_id": NSNull(), "assignment_digest": NSNull(), "decision_id": NSNull(),
         "definition_digest": NSNull(), "node_id": NSNull(), "preview_hash": NSNull(),
         "source_definition_digest": NSNull(), "source_workflow_id": NSNull(), "task_id": NSNull(),
         "token_id": NSNull(), "future_field": NSNull()]
    }

    private func episode(id: String? = nil, state: String, targetRun: String? = nil,
                         targetRole: String = "orchestrator", targetPath: [String]? = nil) -> [String: Any] {
        ["episode_id": id ?? episodeID, "steering_revision": 5, "state": state, "hold": true,
         "target": target(run: targetRun ?? root, role: targetRole, path: targetPath ?? [root])]
    }

    private func envelope(_ fields: [String: Any]) throws -> Data {
        var object: [String: Any] = ["product": "harflow", "format": "harflow.ctl", "v": 1,
                                     "product_version": "0.0.14"]
        object.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func statusWithRawSequence(_ token: String) throws -> Data {
        let base = try status(schema: 1, sequence: 4)
        let json = try #require(String(bytes: base, encoding: .utf8))
        let replaced = json.replacingOccurrences(of: "\"sequence\":4", with: "\"sequence\":\(token)")
        return Data(replaced.utf8)
    }

    private func statusWithDuplicateSequenceKey() throws -> Data {
        let base = try status(schema: 1, sequence: 4)
        let json = try #require(String(bytes: base, encoding: .utf8))
        let duplicated = json.replacingOccurrences(of: "\"sequence\":4", with: "\"sequence\":4,\"sequence\":4")
        return Data(duplicated.utf8)
    }
}
