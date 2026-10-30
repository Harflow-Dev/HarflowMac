import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowPendingInputTests

struct WorkflowPendingInputTests {
    private func status(_ text: String) throws -> WorkflowMonitorStatus {
        let value = try #require(JSONValue.parse(Data(text.utf8))?.objectValue)
        return WorkflowMonitorStatus(value)
    }

    @Test func givenHandoverFixture_whenDecoded_thenInteractionAndInputAreAnswerable() throws {
        // given
        let url = try #require(Bundle.module.url(forResource: "ctl-workflow-interaction-handover", withExtension: "json", subdirectory: "ContractsV1"))
        let document = try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
        let result = try #require(document["result"]?.objectValue)
        // when
        let decoded = WorkflowMonitorStatus(result)
        // then
        let state = try #require(decoded.interactionState)
        #expect(state.owner == .monitor && state.callerState == .dead && state.isAnswerableFromMonitor)
        #expect(state.handover?.previousOwner == "caller" && state.handover?.reason == "pid_absent")
        #expect(decoded.pendingInputs.map(\.decisionID) == ["question-1"])
        #expect(decoded.hasPendingInputsKey)
    }

    @Test(arguments: [
        ("caller", "alive", true), ("caller", "unknown", true), ("caller", "dead", false),
        ("caller", "weird", true), ("future", "dead", true), ("monitor", "alive", false)
    ])
    func givenState_whenAnswerabilityChecked_thenOnlyAvailableKnownOwnersPass(owner: String, caller: String, unavailable: Bool) throws {
        // given
        let available = !unavailable
        let value = try status(#"""
        {"interaction_state":{"owner":"\#(owner)","caller_state":"\#(caller)","monitor_available":\#(available),"reason":"","handover":null}}
        """#)
        // when
        let answerable = value.interactionState?.isAnswerableFromMonitor
        // then
        let expected = available && (owner == "monitor" || (owner == "caller" && caller == "dead"))
        #expect(answerable == expected)
    }

    @Test func givenMissingInteractionState_whenRead_thenNil() throws {
        // given / when
        let value = try status(#"{"status":"needs_input"}"#)
        // then
        #expect(value.interactionState == nil)
    }

    @Test func givenPlainRoot_whenRead_thenFallbackAccessorsAreUsed() throws {
        // given
        let value = try status(#"""
        {"workflow_run_id":"w","status":"needs_input","input_question":"Which?","input_decision_id":"d1","input_question_items":["a",{"text":"b"}],
         "usage_limit_recovery":{"decision_id":"d1","choices":[{"answer":"retry"},{"answer":"switch"}]},
         "monitor_controls":{"resume":{"allowed":true,"reason":""},"additional_attempts":{"allowed":false,"reason":"no"}}}
        """#)
        // then
        #expect(!value.hasPendingInputsKey)
        #expect(value.inputQuestion == "Which?" && value.inputDecisionID == "d1")
        #expect(value.inputQuestionItems == ["a", "b"])
        #expect(value.usageLimitRecovery?.choices == ["retry", "switch"])
        #expect(value.resumeControl?.allowed == true && value.additionalAttemptsControl?.allowed == false)
    }

    @Test func givenTreeRoot_whenRead_thenChildAndUsageLimitEntriesDecode() throws {
        // given
        let value = try status(#"""
        {"workflow_run_id":"root","status":"needs_input","pending_inputs":[
          {"workflow_run_id":"child","workflow_name":"Child","node_id":"n","node_title":"Node","path":["root","child"],
           "decision_id":"d2","question":"Q","question_items":[],"waiting_since":10.5,"optional_review_skip_available":true},
          {"workflow_run_id":"root","decision_id":"d3","question":"Limit","kind":"usage_limit","backend":"claude","model":"m","resume_hint":"pick"},
          {"decision_id":"missing-run"}],
         "pending_attention":[{"workflow_run_id":"x","status":"needs_attention","reason":"stuck","path":["root","x"]},{"status":"paused"}]}
        """#)
        // then
        let inputs = value.pendingInputs
        #expect(inputs.map(\.decisionID) == ["d2", "d3"])
        #expect(inputs[0].path == ["root", "child"] && inputs[0].waitingSince == 10.5 && inputs[0].optionalReviewSkipAvailable)
        #expect(inputs[1].isUsageLimit && inputs[1].backend == "claude" && inputs[1].resumeHint == "pick")
        #expect(value.pendingAttention.map(\.workflowRunID) == ["x"])
        #expect(value.pendingAttention.first?.reason == "stuck")
    }

    @Test func givenBootstrapCatalog_whenRead_thenUnqualified() throws {
        // given
        let value = try status(#"{"catalog_state":{"status":"preparing"}}"#)
        // then
        #expect(!value.isQualified)
    }

    @Test func givenStatusBatch_whenOutcomesRead_thenEachIDHasAResult() async throws {
        // given
        let runner = compatibleRunner { _ in
            ProcessOutput(exitCode: 0, stdout: ctlJSON(#"""
            {"v":11,"tasks":[{"task_id":"a","status":"running","backend":"claude"}],"errors":{"b":{"code":"unknown_task","message":"gone"}}}
            """#), stderr: "", timedOut: false)
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let outcomes = try await client.statusBatchOutcomes(ids: ["a", "b", "c"]).get()
        // then
        #expect((try? outcomes["a"]?.get())?.taskID == "a")
        #expect(outcomes["b"] == .failure(.refused(code: "unknown_task", message: "gone")))
        if case .failure = outcomes["c"] {} else { Issue.record("missing id must be unreadable") }
    }
}
