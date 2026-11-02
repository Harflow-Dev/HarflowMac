import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowSharedInteractionTests

@MainActor
struct WorkflowSharedInteractionTests {
    private func receipt(_ responder: String, sourceRunID: String = "root") -> JSONValue {
        .object(["interaction_id": .string("question-1"), "workflow_run_id": .string(sourceRunID),
                 "action": .string("resume"), "answer": .string("Use production"),
                 "answered_by": .string(responder), "answered_at": .number(1793059200)])
    }

    @Test(arguments: ["root", "nested-child"])
    func givenCallerWins_whenResumeLosesRace_thenWinnerAndDraftRemainAndResubmitIsBlocked(_ sourceRunID: String) async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let error = ToolError.structuredRefusal(code: "workflow_error", message: "Already answered", data: [
            "code": .string("interaction_already_answered"), "interaction": receipt("caller", sourceRunID: sourceRunID)
        ])
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willThrow(error)
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("root"), "status": .string("needs_input"),
                                                         "input_decision_id": .string("question-1"), "interaction_owner": .string("caller"),
                                                         "monitor_controls": .object(["resume": .object(["allowed": .bool(true)])])])
        harness.sut.instructions = "Use staging"
        // when
        harness.sut.control("resume")
        await waitUntil { !harness.sut.isBusy && harness.sut.interactionOutcome != nil }
        // then
        #expect(harness.sut.interactionOutcome?.answer == "Use production")
        #expect(harness.sut.interactionOutcome?.answeredBy == .caller)
        #expect(harness.sut.interactionSavedDraft == "Use staging")
        #expect(harness.sut.instructions == "Use staging")
        harness.sut.control("resume")
        verify(harness.useCase).command(.value("resume"), options: .any, positionals: .any, runtime: .any).called(1)
    }

    @Test func givenHarflowWins_whenResumeSucceeds_thenEngineReceiptRetainsMonitorAttribution() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let raw: [String: JSONValue] = ["workflow_run_id": .string("root"), "status": .string("running"),
                                         "interaction_history": .array([receipt("monitor")])]
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn(raw)
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("root"), "status": .string("needs_input"),
                                                         "input_decision_id": .string("question-1"), "interaction_owner": .string("caller"),
                                                         "monitor_controls": .object(["resume": .object(["allowed": .bool(true)])])])
        harness.sut.instructions = "Use production"
        // when
        harness.sut.control("resume")
        await waitUntil { !harness.sut.isBusy && harness.sut.interactionOutcome != nil }
        // then
        #expect(harness.sut.interactionOutcome?.answeredBy == .monitor)
        #expect(harness.sut.interactionOutcome?.answer == "Use production")
        #expect(harness.sut.interactionSavedDraft == nil)
    }
}
