import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowDelegationTests

@MainActor
struct WorkflowDelegationTests {
    @Test func givenWorkerContract_whenPresented_thenResultAndEvidenceAreReadable() {
        // given
        let contract = "{\"status\":\"succeeded\",\"result\":{\"verdict\":\"changes_needed\","
        + "\"findings\":[\"Missing empty input\"]},\"evidence\":[\"Ran tests\"]}"
        // when
        let display = WorkflowNodePresentation.summary(contract)
        // then
        #expect(display?.contains("Succeeded") == true)
        #expect(display?.contains("Missing empty input") == true)
        #expect(display?.contains("Ran tests") == true)
        #expect(display?.contains("{\"") == false)
        #expect(WorkflowNodePresentation.summary("Ordinary response") == "Ordinary response")
    }

    @Test func givenAgentDecidesStarter_whenCreated_thenEveryWorkerLetsAgentDecide() {
        // given
        let definition = WorkflowVM.starterDefinition()
        // when
        let nodes = WorkflowJSON.nodes(definition).filter { $0.type == "agent" }
        // then
        #expect(nodes.allSatisfy { $0.raw["session_mode"]?.stringValue == "agent_decides" })
    }

    @Test func givenSettlingFailedRun_whenRecoverRequested_thenNoCommandDispatched() async {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "execution_contract": .string("delegation"),
                                                       "status": .string("failed"), "settling": .bool(true)])
        harness.sut.instructions = "Investigated and approved"
        // when
        harness.sut.control("recover")
        // then
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
        #expect(harness.sut.selectedRun?.canRecover == false)
    }

    @Test func givenFailedDelegation_whenRecovered_thenReasonAndGrantSubmitted() async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "execution_contract": .string("delegation"),
                                                       "status": .string("failed")])
        harness.sut.instructions = "Investigated and approved"
        harness.sut.additionalAttempts = 2
        // when
        harness.sut.control("recover")
        // then
        await verify(harness.useCase)
.command(.value("recover"), options: .value(["--reason=Investigated and approved", "--additional-attempts=2"]),
                                            positionals: .value(["run"]))
.calledEventually(1, before: .seconds(5))
    }

    @Test(arguments: [false, true])
    func givenUnansweredInputRun_whenCancelled_thenCancellationBypassesRecoveryGuards(settling: Bool) async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "execution_contract": .string("delegation"),
                                                       "status": .string("needs_input"), "settling": .bool(settling)])
        harness.sut.instructions = ""
        // when
        harness.sut.control("cancel")
        // then
        await verify(harness.useCase)
.command(.value("cancel"), options: .value([]), positionals: .value(["run"]))
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenWorkflowMetadata_whenProjectionSelected_thenOnlyDelegationWorkersDecode() throws {
        // given
        let worker = try #require(TaskInfo(.object(["task_id": .string("worker"), "workflow_role": .string("node"),
                                                    "execution_contract": .string("delegation")])))
        let historical = try #require(TaskInfo(.object(["task_id": .string("old"), "workflow_role": .string("node")])))
        let orchestrator = try #require(TaskInfo(.object(["task_id": .string("decision"), "workflow_role": .string("orchestrator"),
                                                          "execution_contract": .string("delegation")])))
        // when / then
        #expect(WorkflowNodePresentation.isWorker(worker))
        #expect(!WorkflowNodePresentation.isWorker(historical))
        #expect(!WorkflowNodePresentation.isWorker(orchestrator))
    }

    @Test func givenWorkflowTask_whenRunUnfinished_thenTerminalIsHidden() throws {
        // given
        let raw: [String: JSONValue] = ["task_id": .string("node"), "workflow_run_id": .string("run")]
        let running = try #require(TaskInfo(.object(raw)))
        var completedRaw = raw
        completedRaw["workflow_status"] = .string("completed")
        let completed = try #require(TaskInfo(.object(completedRaw)))
        // when / then
        #expect(!WorkflowNodePresentation.allowsTerminal(running))
        #expect(WorkflowNodePresentation.allowsTerminal(completed))
        #expect(!WorkflowRunModel(raw: ["interaction_owner": .string("caller")]).allowsMonitorControl)
    }

    @Test func givenMonitorInputQuestion_whenAnswered_thenOwnershipAndDecisionIdentitySubmitted() async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "execution_contract": .string("delegation"),
                                                       "status": .string("needs_input"), "interaction_owner": .string("monitor"),
                                                       "input_decision_id": .string("question-1")])
        harness.sut.instructions = "Use existing implementation"
        // when
        harness.sut.control("resume")
        // then
        await verify(harness.useCase)
.command(.value("resume"),
            options: .value(["--monitor", "--instructions=Use existing implementation", "--additional-attempts=0", "--decision-id=question-1"]),
            positionals: .value(["run"]))
.calledEventually(1, before: .seconds(5))
    }

    @Test func givenAskingContract_whenDisplayed_thenQuestionShownWithContextLabel() {
        // given
        let contract = "{\"status\":\"asking\",\"result\":{\"question\":\"Which endpoint?\"},\"evidence\":[]}"
        // when
        let display = WorkflowNodePresentation.summary(contract)
        // then
        #expect(display?.contains("Asking for context") == true)
        #expect(display?.contains("Which endpoint?") == true)
    }

    @Test func givenFailedRetryBudget_whenOneMoreRetryApproved_thenRecoverGetsOneGrant() async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "execution_contract": .string("delegation"),
                                                       "status": .string("failed"), "exhausted_retry_edges": .array([.string("retry")])])
        harness.sut.additionalAttempts = 8
        // when — no reason does not consume or change the grant.
        harness.sut.continueWithOneMoreRetry()
        // then
        #expect(harness.sut.additionalAttempts == 8)
        harness.sut.instructions = "Reviewed failure"
        harness.sut.continueWithOneMoreRetry()
        await verify(harness.useCase)
.command(.value("recover"), options: .value(["--reason=Reviewed failure", "--additional-attempts=1"]),
                                            positionals: .value(["run"]))
.calledEventually(1, before: .seconds(5))
    }

    @Test func givenUnloadedRun_whenControlAvailabilityChecked_thenControlsWaitForLoadedProvenance() {
        // given
        let placeholder = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        let historical = WorkflowRunModel(raw: ["workflow_run_id": .string("old"), "status": .string("running")])
        let external = WorkflowRunModel(raw: ["status": .string("running"), "interaction_owner": .string("caller")])
        // when / then
        #expect(!placeholder.allowsMonitorControl)
        #expect(historical.allowsMonitorControl)
        #expect(!external.allowsMonitorControl)
    }

    @Test func givenQuestionRepliesAndFallback_whenAttemptLabelsBuilt_thenOnlyActualFallbackAdvancesIndex() {
        // given
        let activation: [String: JSONValue] = [
            "tasks": .array(["primary", "reply", "fallback", "fallback-reply"].map { .object(["task_id": .string($0)]) }),
            "questions": .array(["reply", "fallback-reply"].map { .object(["reply_task_id": .string($0)]) })
        ]
        // when
        let indices = WorkflowExecutionAttempts.fallbackIndices(activation)
        // then
        #expect(indices == ["primary": 0, "reply": 0, "fallback": 1, "fallback-reply": 1])
    }

}
