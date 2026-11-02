import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowSharedInteractionTests

struct WorkflowSharedInteractionTests {
    private func receipt(responder: String = "caller") -> JSONValue {
        .object(["interaction_id": .string("question-1"), "workflow_run_id": .string("root"),
                 "action": .string("resume"), "answer": .string("Use staging"),
                 "answered_by": .string(responder), "answered_at": .number(1793059200)])
    }

    @Test func givenSharedProjection_whenDecoded_thenExplicitRespondersAndWinnerAreRetained() throws {
        // given
        let raw: [String: JSONValue] = [
            "interaction_state": .object(["owner": .string("caller"), "caller_state": .string("alive"),
                                           "monitor_available": .bool(true), "responders": .array([.string("caller"), .string("monitor")])]),
            "interaction_history": .array([receipt()])
        ]
        // when
        let status = WorkflowMonitorStatus(raw)
        let winner = try #require(status.interactionHistory.first)
        // then
        #expect(status.interactionState?.responders == ["caller", "monitor"])
        #expect(winner.answeredBy == .caller)
        #expect(winner.interactionID == "question-1" && winner.answer == "Use staging")
        #expect(winner.action == "resume" && winner.workflowRunID == "root")
    }

    @Test(arguments: ["caller", "monitor"])
    func givenLostRace_whenRefusalDecoded_thenPersistedWinnerIsRetained(_ responder: String) throws {
        // given
        let error = ToolError.structuredRefusal(code: "workflow_error", message: "Already answered", data: [
            "code": .string("interaction_already_answered"), "interaction": receipt(responder: responder)
        ])
        // when
        let winner = try #require(error.workflowInteractionWinner)
        // then
        #expect(winner.answeredBy.rawValue == responder)
        #expect(winner.answeredAt == 1793059200)
    }

    @Test(arguments: ["alive", "dead", "unknown"])
    func givenSharedResponders_whenMonitorAvailabilityIsExplicit_thenCallerLivenessDoesNotDisableAnswer(_ caller: String) {
        // given
        let value: JSONValue = .object(["owner": .string("caller"), "caller_state": .string(caller),
                                        "monitor_available": .bool(true), "responders": .array([.string("caller"), .string("monitor")])])
        // when / then
        #expect(WorkflowInteractionState(value)?.isAnswerableFromMonitor == true)
    }

    @Test func givenExplicitCallerOnlyResponders_whenCallerIsDead_thenLegacyFallbackDoesNotGrantAuthority() {
        // given
        let value: JSONValue = .object(["owner": .string("caller"), "caller_state": .string("dead"),
                                        "monitor_available": .bool(true), "responders": .array([.string("caller")])])
        // when / then
        #expect(WorkflowInteractionState(value)?.isAnswerableFromMonitor == false)
    }

    @Test func givenMalformedExplicitResponders_whenCallerIsDead_thenNoLegacyAuthorityIsGranted() {
        // given
        let value: JSONValue = .object(["owner": .string("caller"), "caller_state": .string("dead"),
                                        "monitor_available": .bool(true), "responders": .array([.number(1)])])
        // when / then
        #expect(WorkflowInteractionState(value)?.isAnswerableFromMonitor == false)
    }

    @Test func givenPersistedApprovalWinner_whenRefused_thenTaskScopedOutcomeIsRetained() throws {
        // given
        let winner: JSONValue = .object(["interaction_id": .string("approval-1"), "task_id": .string("task-1"),
                                         "action": .string("approval"), "answer": .string("reject"),
                                         "answered_by": .string("caller"), "answered_at": .number(1793059200)])
        let error = ToolError.structuredRefusal(code: "approval_error", message: "Already decided", data: ["interaction": winner])
        // when
        let result = try #require(error.callerApprovalWinner)
        // then
        #expect(result.taskID == "task-1" && result.requestID == "approval-1")
        #expect(result.decision == "reject" && result.answeredBy == .caller)
    }

    @Test func givenUnknownWinnerOrLegacyState_whenDecoded_thenNoProvenanceIsInvented() {
        // given / when
        let status = WorkflowMonitorStatus(["interaction_state": .object(["owner": .string("caller")]),
                                            "interaction_history": .array([receipt(responder: "future"), .object([:])])])
        let legacy = ToolError.refused(code: "workflow_error", message: "Already answered")
        // then
        #expect(status.interactionState?.responders == nil)
        #expect(status.interactionHistory.isEmpty)
        #expect(legacy.workflowInteractionWinner == nil)
    }
}
