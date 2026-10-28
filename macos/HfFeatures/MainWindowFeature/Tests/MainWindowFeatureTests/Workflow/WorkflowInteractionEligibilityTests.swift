import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowInteractionEligibilityTests

struct WorkflowInteractionEligibilityTests {
    @Test func givenCallerOwnedRoot_whenEngineGrantsRecovery_thenEligibilityUsesEngineEvidence() {
        // given
        let run = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "status": .string("needs_attention"),
            "interaction_owner": .string("caller"), "monitor_controls": .object([
                "resume": .object(["allowed": .bool(true), "reason": .string("")])])])
        // when / then
        #expect(!run.allowsMonitorControl)
        #expect(run.permitsMonitor("resume", fallback: run.allowsMonitorControl))
        #expect(WorkflowRecoveryPresentation.showsRecovery(run))
    }

    @Test func givenRefreshedEngineRefusal_whenOwnerLooksEligible_thenEngineRefusalWins() {
        // given
        let run = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "status": .string("paused"),
            "interaction_owner": .string("monitor"), "monitor_controls": .object([
                "resume": .object(["allowed": .bool(false), "reason": .string("Running branches are settling.")])])])
        // when / then
        #expect(!run.permitsMonitor("resume", fallback: true))
        #expect(run.monitorReason("resume") == "Running branches are settling.")
        #expect(WorkflowRecoveryPresentation.showsRecovery(run))
    }

    @Test func givenChildOrLegacyCaller_whenNoCapabilityExists_thenControlsStayConservativeAndDetailsVisible() {
        // given
        let child = WorkflowRunModel(raw: ["workflow_run_id": .string("child"), "status": .string("needs_input"),
            "parent_workflow_run_id": .string("root"), "root_workflow_run_id": .string("root")])
        // when / then
        #expect(WorkflowRecoveryPresentation.showsRecovery(child))
        #expect(!child.permitsMonitor("resume", fallback: child.allowsMonitorControl))
        #expect(child.monitorReason("resume")?.contains("root") == true)
    }
}

@MainActor
struct WorkflowRecoveryControlEligibilityTests {
    @Test(arguments: ["starting", "running", "cancelling"])
    func givenInterruptedScheduler_whenEngineAllowsRecovery_thenRecoverVisibleWithoutAttemptGrant(_ status: String) async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        let run = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "status": .string(status),
            "interaction_owner": .string("caller"), "monitor_controls": .object([
                "recover": .object(["allowed": .bool(true)]),
                "additional_attempts": .object(["allowed": .bool(false)])])])
        harness.sut.selectedRun = run
        harness.sut.additionalAttempts = 12
        harness.sut.instructions = "Restore the interrupted scheduler."
        // when
        harness.sut.control(run.recoveryCommand)
        // then
        #expect(run.isSchedulerRecovery)
        #expect(WorkflowRecoveryPresentation.showsRecovery(run))
        #expect(run.recoveryCommand == "recover")
        await verify(harness.useCase)
            .command(.value("recover"), options: .value(["--monitor", "--reason=Restore the interrupted scheduler."]),
                     positionals: .value(["run"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenForwardedChildQuestionWhileSiblingSettles_whenEngineAllowsAnswer_thenResumeIsNotBlockedByLocalSettlingHeuristic() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        let run = WorkflowRunModel(raw: ["workflow_run_id": .string("root"), "status": .string("needs_input"),
            "settling": .bool(true), "execution_contract": .string("delegation"),
            "interaction_owner": .string("caller"), "input_decision_id": .string("child-question"),
            "monitor_controls": .object(["resume": .object(["allowed": .bool(true)])])])
        harness.sut.selectedRun = run
        harness.sut.instructions = "Continue with the documented scope."
        // when
        harness.sut.control("resume")
        // then
        #expect(run.canSubmitContinuation("resume", instructions: harness.sut.instructions))
        await verify(harness.useCase)
            .command(.value("resume"), options: .value(["--monitor", "--instructions=Continue with the documented scope.",
                "--additional-attempts=0", "--decision-id=child-question"]), positionals: .value(["root"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test(arguments: ["running", "needs_input"])
    func givenEngineAllowsContinuation_whenRequiredInputIsBlank_thenNoCommandIsIssued(_ status: String) {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let command = status == "running" ? "recover" : "resume"
        let run = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "status": .string(status),
            "execution_contract": .string("delegation"), "monitor_controls": .object([
                command: .object(["allowed": .bool(true)])])])
        harness.sut.selectedRun = run
        harness.sut.instructions = " \n "
        // when
        harness.sut.control(command)
        // then
        #expect(!run.canSubmitContinuation(command, instructions: harness.sut.instructions))
        verify(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).called(0)
    }

    @Test func givenForwardedOptionalReviewWithSettlingSibling_whenEngineAllowsConsent_thenCurrentCheckpointStillRequired() {
        // given
        var raw: [String: JSONValue] = ["workflow_run_id": .string("root"), "status": .string("needs_input"),
            "settling": .bool(true), "execution_contract": .string("delegation"),
            "interaction_owner": .string("caller"), "input_decision_id": .string("child-question"),
            "optional_review_skip_available": .bool(true), "monitor_controls": .object([
                "resume": .object(["allowed": .bool(true)]),
                "skip_optional_review": .object(["allowed": .bool(true)])])]
        let run = WorkflowRunModel(raw: raw)
        // when / then
        #expect(run.canSkipOptionalReview)
        #expect(run.canSubmitContinuation("resume", instructions: "Proceed without this optional reviewer."))
        #expect(!run.canSubmitContinuation("resume", instructions: ""))
        raw.removeValue(forKey: "input_decision_id")
        #expect(!WorkflowRunModel(raw: raw).canSkipOptionalReview)
    }
}
