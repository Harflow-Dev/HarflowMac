import Foundation
@testable import HfRepository
import MonitorCore
import Testing

@Suite struct NeedsYouNotificationRouteTests {
    private func item(_ id: String, _ kind: NeedsYouItem.Kind, root: String = "", task: String? = nil, decision: String? = nil,
                      approval: String? = nil) -> NeedsYouItem {
        NeedsYouItem(
            id: id, kind: kind, rootRunID: root, runTitle: "Run", text: "t",
            ownership: .init(owner: "monitor", callerEnded: false, engineNote: "", handover: nil), startedBy: "Mac app",
            decisionID: decision,
            approval: approval.map { CallerApprovalRequest(raw: ["request_id": .string($0)]) }, taskID: task
        )
    }

    private var snapshot: NeedsYouSnapshot {
        NeedsYouSnapshot(phase: .ready, items: [
            item("input:w1:d1", .question, root: "w1", decision: "d1"),
            item("input:w1:d2", .question, root: "w1", decision: "d2"),
            item("attention:w1:c1", .recovery, root: "w1"),
            item("approval:t1:r1", .approval, task: "t1", approval: "r1")
        ])
    }

    private func route(_ info: [AnyHashable: Any]) -> NeedsYouNotificationRoute? {
        NeedsYouNotificationRoute.destination(userInfo: info, snapshot: snapshot)
    }

    @Test func givenATaskIDWithoutAKind_whenRouted_thenItOpensTheTask() {
        #expect(route(["task_id": "t1", "workflow_run_id": "w1"]) == .task("t1"))
    }

    @Test func givenAQuestion_whenRouted_thenItOpensTheItemWithThatDecision() {
        #expect(route(["needs_you_kind": "question", "workflow_run_id": "w1", "interaction_id": "d2"]) == .needsYou(itemID: "input:w1:d2"))
    }

    @Test func givenAnUnmatchedQuestion_whenRouted_thenItOpensTheList() {
        #expect(route(["needs_you_kind": "question", "workflow_run_id": "w1", "interaction_id": "gone"]) == .needsYou(itemID: nil))
    }

    @Test func givenAQuestionWithoutAnInteractionID_whenRouted_thenItOpensTheList() {
        #expect(route(["needs_you_kind": "question", "workflow_run_id": "w1"]) == .needsYou(itemID: nil))
        #expect(route(["needs_you_kind": "approval", "task_id": "t1"]) == .needsYou(itemID: nil))
    }

    @Test func givenAnApproval_whenRouted_thenItOpensTheItemWithThatTaskAndRequest() {
        #expect(route(["needs_you_kind": "approval", "task_id": "t1", "interaction_id": "r1"]) == .needsYou(itemID: "approval:t1:r1"))
        #expect(route(["needs_you_kind": "approval", "task_id": "t1", "interaction_id": "other"]) == .needsYou(itemID: nil))
    }

    @Test func givenARecovery_whenRouted_thenItOpensTheRecoveryOfThatRootIgnoringTheInteractionKey() {
        #expect(route(["needs_you_kind": "recovery", "workflow_run_id": "w1", "interaction_id": "point-key"]) == .needsYou(itemID: "attention:w1:c1"))
    }

    @Test func givenARecoveryWithNoMatch_whenRouted_thenItOpensTheList() {
        #expect(route(["needs_you_kind": "recovery", "workflow_run_id": "w9"]) == .needsYou(itemID: nil))
    }

    @Test func givenAnUnknownKind_whenRouted_thenItOpensTheList() {
        #expect(route(["needs_you_kind": "future", "workflow_run_id": "w1"]) == .needsYou(itemID: nil))
    }

    @Test func givenALegacyRunOnlyBanner_whenRouted_thenItOpensTheRun() {
        #expect(route(["workflow_run_id": "w1"]) == .workflowRun("w1"))
    }

    @Test func givenALegacyItemBanner_whenRouted_thenItOpensThatItem() {
        #expect(route(["needs_you_item": "input:w1:d1"]) == .needsYou(itemID: "input:w1:d1"))
    }

    @Test func givenNoKnownKey_whenRouted_thenThereIsNoDestination() {
        #expect(route([:]) == nil)
    }
}
