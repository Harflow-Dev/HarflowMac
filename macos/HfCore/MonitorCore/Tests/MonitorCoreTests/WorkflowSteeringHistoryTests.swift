import Foundation
@testable import MonitorCore
import Testing

struct WorkflowSteeringHistoryTests {
    private let root = String(repeating: "a", count: 32)
    private let episodeID = String(repeating: "c", count: 32)
    private let requestID = "0f8a560b-19e5-4e11-afb5-9edcb44c9d13"

    @Test func givenExactLaterRequestedRow_whenHistoryHasGap_thenPositiveAdmissionStillProvesRequest() throws {
        let before = try status(sequence: 10)
        let request = try WorkflowSteeringRequest(status: before, action: .open, text: "start",
                                                  requestID: UUID(uuidString: requestID)!)
        let after = try status(sequence: 11, episodes: [episodeObject()])
        let page = try history(rows: [row(sequence: 11, id: requestID, text: "start")], gap: true, incomplete: true)
        #expect(page.admissionEvidence(for: request, status: after)?.sequence == 11)
    }

    @Test func givenOnlyOlderOrMismatchedHistoryRows_whenProvingAdmission_thenReturnsNoEvidence() throws {
        let before = try status(sequence: 10)
        let request = try WorkflowSteeringRequest(status: before, action: .open, text: "start",
                                                  requestID: UUID(uuidString: requestID)!)
        let after = try status(sequence: 12, episodes: [episodeObject()])
        let older = try history(rows: [row(sequence: 9, id: requestID, text: "start")])
        let mismatch = try history(rows: [row(sequence: 11, id: requestID, text: "different")])
        let unicodeRequest = try WorkflowSteeringRequest(status: before, action: .open, text: "é",
                                                        requestID: UUID(uuidString: requestID)!)
        let normalizedUnicodeMismatch = try history(rows: [row(sequence: 11, id: requestID, text: "e\u{301}")])
        #expect(older.admissionEvidence(for: request, status: after) == nil)
        #expect(mismatch.admissionEvidence(for: request, status: after) == nil)
        #expect(normalizedUnicodeMismatch.admissionEvidence(for: unicodeRequest, status: after) == nil)
    }

    @Test func givenUnorderedHistoryRows_whenDecoding_thenRejectsPage() throws {
        let rows = [row(sequence: 12, id: requestID, text: "start"), row(sequence: 11, id: requestID, text: "start")]
        #expect(WorkflowSteeringHistoryPage(data: try historyData(rows: rows), rootID: root) == nil)
    }

    private func status(sequence: Int64, episodes: [[String: Any]] = []) throws -> WorkflowSteeringStatus {
        let result: [String: Any] = ["root_workflow_run_id": root, "steering_version": 1,
            "request_schema_version": 2, "ledger_epoch": 5, "interaction_epoch": 3,
            "control_revision": 4, "sequence": sequence, "owner": "monitor",
            "eligible_actions": ["open", "reply", "retarget", "dismiss"],
            "targets": [targetObject()], "episodes": episodes]
        return try #require(WorkflowSteeringStatus(data: try envelope(result), rootID: root))
    }

    private func targetObject() -> [String: Any] {
        ["root_workflow_run_id": root, "workflow_run_id": root, "path": [root], "role": "orchestrator",
         "checkpoint_revision": 1, "goal_revision": 2, "interaction_epoch": 3, "control_revision": 4,
         "assignment_revision": NSNull(), "draft_revision": NSNull(), "source_revision": NSNull(),
         "activation_id": NSNull(), "assignment_digest": NSNull(), "decision_id": NSNull(),
         "definition_digest": NSNull(), "node_id": NSNull(), "preview_hash": NSNull(),
         "source_definition_digest": NSNull(), "source_workflow_id": NSNull(), "task_id": NSNull(), "token_id": NSNull()]
    }

    private func episodeObject() -> [String: Any] {
        ["episode_id": episodeID, "steering_revision": 6, "state": "pending", "hold": true, "target": targetObject()]
    }

    private func row(sequence: Int, id: String, text: String) -> [String: Any] {
        ["sequence": sequence, "kind": "requested", "action": "open", "request_id": id,
         "episode_id": episodeID, "turn_id": NSNull(), "outcome": NSNull(), "text": text]
    }

    private func history(rows: [[String: Any]], gap: Bool = false, incomplete: Bool = false) throws -> WorkflowSteeringHistoryPage {
        try #require(WorkflowSteeringHistoryPage(data: try historyData(rows: rows, gap: gap, incomplete: incomplete), rootID: root))
    }

    private func historyData(rows: [[String: Any]], gap: Bool = false, incomplete: Bool = false) throws -> Data {
        let result: [String: Any] = ["root_workflow_run_id": root, "items": rows, "has_more": false,
                                     "next_cursor": NSNull(), "gap": gap, "history_incomplete": incomplete]
        return try envelope(result)
    }

    private func envelope(_ result: [String: Any]) throws -> Data {
        let object: [String: Any] = ["product": "harflow", "format": "harflow.ctl", "v": 1,
                                     "product_version": "0.0.14", "result": result]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
