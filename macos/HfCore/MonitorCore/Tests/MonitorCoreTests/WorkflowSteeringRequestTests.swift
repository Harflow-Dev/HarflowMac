import Foundation
@testable import MonitorCore
import Testing

struct WorkflowSteeringRequestTests {
    private let root = String(repeating: "a", count: 32)
    private let episodeID = String(repeating: "c", count: 32)

    @Test func givenRootOpenStatus_whenCreatingRequest_thenUsesFreshIDExactTextAndDisablesFreshContext() throws {
        let status = try #require(WorkflowSteeringStatus(data: statusData(episodes: []), rootID: root))
        let id = UUID(uuidString: "0F8A560B-19E5-4E11-AFB5-9EDCB44C9D13")!
        let text = "  Keep this exact 🦋\n--monitor  "
        let request = try WorkflowSteeringRequest(status: status, action: .open, text: text, requestID: id)
        let object = try #require(JSONSerialization.jsonObject(with: request.data) as? [String: Any])

        #expect(request.requestID == id.uuidString.lowercased())
        #expect(request.text == text)
        #expect(object["text"] as? String == text)
        #expect(object["allow_fresh_context"] as? Bool == false)
        #expect(object["action"] as? String == "open")
        #expect(object["request_id"] as? String == request.requestID)
    }

    @Test func givenHeldRootEpisode_whenCreatingDismiss_thenBindsEpisodeAndOmitsText() throws {
        let status = try #require(WorkflowSteeringStatus(data: statusData(episodes: [heldEpisode()]), rootID: root))
        let request = try WorkflowSteeringRequest(status: status, action: .dismiss)
        let object = try #require(JSONSerialization.jsonObject(with: request.data) as? [String: Any])
        #expect(request.episodeID == episodeID)
        #expect(object["episode_id"] as? String == episodeID)
        #expect(object["text"] == nil)
        #expect(object["allow_fresh_context"] == nil)
    }

    @Test func givenStaleHeldTarget_whenDismissingOrRetargeting_thenDismissKeepsOriginalAndRetargetUsesFreshRoot() throws {
        let status = try #require(WorkflowSteeringStatus(
            data: statusData(episodes: [heldEpisode(state: "stale", goalRevision: 1)], targetGoalRevision: 2), rootID: root
        ))
        let dismiss = try WorkflowSteeringRequest(status: status, action: .dismiss)
        let retarget = try WorkflowSteeringRequest(status: status, action: .retarget, text: "continue")
        let dismissObject = try #require(JSONSerialization.jsonObject(with: dismiss.data) as? [String: Any])
        let retargetObject = try #require(JSONSerialization.jsonObject(with: retarget.data) as? [String: Any])
        let dismissTarget = try #require(dismissObject["target"] as? [String: Any])
        let retargetTarget = try #require(retargetObject["target"] as? [String: Any])

        #expect(dismissTarget["goal_revision"] as? Int == 1)
        #expect(retargetTarget["goal_revision"] as? Int == 2)
        #expect(retargetObject["supersedes_episode_id"] as? String == episodeID)
    }

    @Test func givenAwaitingReplyWithMovedTarget_whenCreatingReply_thenRefusesStaleTarget() throws {
        let status = try #require(WorkflowSteeringStatus(
            data: statusData(episodes: [heldEpisode(state: "awaiting_caller", goalRevision: 1)], targetGoalRevision: 2), rootID: root
        ))
        #expect(throws: (any Error).self) {
            try WorkflowSteeringRequest(status: status, action: .reply, text: "answer")
        }
    }

    @Test(arguments: ["awaiting_caller", "command_refused"])
    func givenRetainedEpisodeWithExplicitRetargetAndReplyAbsent_whenRequestingAction_thenOnlyRetargetIsAuthorized(state: String) throws {
        let status = try #require(WorkflowSteeringStatus(
            data: statusData(episodes: [heldEpisode(state: state)], eligibleActions: ["dismiss", "retarget"]), rootID: root
        ))

        let retarget = try WorkflowSteeringRequest(status: status, action: .retarget, text: "reconsider")

        #expect(retarget.action == .retarget)
        #expect(status.permits(.retarget))
        #expect(!status.permits(.reply))
        #expect(throws: (any Error).self) {
            try WorkflowSteeringRequest(status: status, action: .reply, text: "answer")
        }
    }

    @Test func givenAwaitingCallerWithoutRetargetAuthorization_whenCreatingRetarget_thenRefusesIt() throws {
        let status = try #require(WorkflowSteeringStatus(
            data: statusData(episodes: [heldEpisode(state: "awaiting_caller")], eligibleActions: ["dismiss", "reply"]), rootID: root
        ))

        #expect(!status.permits(.retarget))
        #expect(throws: (any Error).self) {
            try WorkflowSteeringRequest(status: status, action: .retarget, text: "reconsider")
        }
    }

    @Test func givenReplyTextThatExceedsUTF8Bound_whenCreatingRequest_thenRejectsIt() throws {
        let status = try #require(WorkflowSteeringStatus(data: statusData(episodes: [heldEpisode()]), rootID: root))
        #expect(throws: (any Error).self) {
            try WorkflowSteeringRequest(status: status, action: .reply, text: String(repeating: "🦋", count: 8193))
        }
    }

    @Test func givenAsciiControlTextWithinUTF8BoundButOverProducerJSONLimit_whenCreatingRequest_thenRejectsIt() throws {
        let status = try #require(WorkflowSteeringStatus(data: statusData(episodes: []), rootID: root))
        let text = String(repeating: "\u{7f}", count: 21_845)
        #expect(text.utf8.count <= 32_768)
        #expect(throws: (any Error).self) {
            try WorkflowSteeringRequest(status: status, action: .open, text: text)
        }
    }

    @Test func givenMatchingReceipt_whenValidating_thenRequiresFreshLaterSequenceAndOriginalEpoch() throws {
        let status = try #require(WorkflowSteeringStatus(data: statusData(episodes: []), rootID: root))
        let request = try WorkflowSteeringRequest(status: status, action: .open, text: "start")
        let receipt = try receiptData(requestID: request.requestID, sequence: status.sequence + 1, epoch: status.interactionEpoch)
        #expect(WorkflowSteeringReceipt(data: receipt, matching: request)?.requestID == request.requestID)
        let sameSequence = try receiptData(requestID: request.requestID, sequence: status.sequence, epoch: status.interactionEpoch)
        let changedEpoch = try receiptData(requestID: request.requestID, sequence: status.sequence + 1, epoch: status.interactionEpoch + 1)
        let changedLedger = try receiptData(requestID: request.requestID, sequence: status.sequence + 1,
                                            epoch: status.interactionEpoch, ledgerEpoch: 6)
        #expect(WorkflowSteeringReceipt(data: sameSequence, matching: request) == nil)
        #expect(WorkflowSteeringReceipt(data: changedEpoch, matching: request) == nil)
        #expect(WorkflowSteeringReceipt(data: changedLedger, matching: request) == nil)
    }

    private func statusData(episodes: [[String: Any]], targetGoalRevision: Int = 2,
                            eligibleActions: [String] = ["open", "reply", "retarget", "dismiss"]) throws -> Data {
        let target = targetObject(goalRevision: targetGoalRevision)
        return try envelope(["root_workflow_run_id": root, "steering_version": 1, "request_schema_version": 2,
                         "ledger_epoch": 5, "interaction_epoch": 3, "control_revision": 4, "sequence": 10,
                         "owner": "monitor", "eligible_actions": eligibleActions,
                         "targets": [target], "episodes": episodes])
    }

    private func targetObject(goalRevision: Int = 2) -> [String: Any] {
        ["root_workflow_run_id": root, "workflow_run_id": root, "path": [root], "role": "orchestrator",
         "checkpoint_revision": 1, "goal_revision": goalRevision, "interaction_epoch": 3, "control_revision": 4,
         "assignment_revision": NSNull(), "draft_revision": NSNull(), "source_revision": NSNull(),
         "activation_id": NSNull(), "assignment_digest": NSNull(), "decision_id": NSNull(), "definition_digest": NSNull(),
         "node_id": NSNull(), "preview_hash": NSNull(), "source_definition_digest": NSNull(),
         "source_workflow_id": NSNull(), "task_id": NSNull(), "token_id": NSNull()]
    }

    private func heldEpisode(state: String = "awaiting_caller", goalRevision: Int = 2) -> [String: Any] {
        ["episode_id": episodeID, "steering_revision": 6, "state": state, "hold": true, "target": targetObject(goalRevision: goalRevision)]
    }

    private func receiptData(requestID: String, sequence: Int64, epoch: Int64, ledgerEpoch: Int64 = 5) throws -> Data {
        try envelope(["accepted": true, "request_id": requestID, "episode_id": episodeID, "steering_revision": 7,
                      "interaction_epoch": epoch, "control_revision": 4, "ledger_epoch": ledgerEpoch, "sequence": sequence,
                  "scheduled": false, "replayed": false, "state": "pending"])
    }

    private func envelope(_ result: [String: Any]) throws -> Data {
        let object: [String: Any] = ["product": "harflow", "format": "harflow.ctl", "v": 1,
                                     "product_version": "0.0.14", "result": result]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
