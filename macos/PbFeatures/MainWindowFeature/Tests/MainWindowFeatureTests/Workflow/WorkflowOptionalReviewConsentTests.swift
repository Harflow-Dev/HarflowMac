import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

@MainActor
struct WorkflowOptionalReviewConsentTests {
    private func inputRun() -> WorkflowRunModel {
        WorkflowRunModel(raw: [
            "workflow_run_id": .string("root-run"),
            "execution_contract": .string("delegation"),
            "status": .string("needs_input"),
            "interaction_owner": .string("monitor"),
            "input_decision_id": .string("child-question"),
            "optional_review_skip_available": .bool(true),
            "attention_source_run_id": .string("child-run")
        ])
    }

    @Test(arguments: [false, true])
    func givenDisplayedCheckpoint_whenResumingThenChangingSelection_thenCapturesAnswerAndConsent(explicitConsent: Bool) async {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        vm.selectedRun = inputRun()
        vm.instructions = "Keep the required review"
        vm.additionalAttempts = 2

        // when
        if explicitConsent {
            vm.control("resume", allowOptionalReviewSkip: true)
        } else {
            vm.control("resume")
        }
        // The scheduled closure has not run yet: changing the screen must not change its payload.
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("different-run"),
                                               "status": .string("needs_input"),
                                               "input_decision_id": .string("different-question")])
        vm.instructions = "Different answer"
        vm.additionalAttempts = 9

        // then
        var options = ["--monitor", "--instructions=Keep the required review", "--additional-attempts=2",
                       "--decision-id=child-question"]
        if explicitConsent { options.append("--allow-optional-review-skip") }
        await verify(harness.useCase)
            .command(.value("resume"), options: .value(options), positionals: .value(["root-run"]))
            .calledEventually(1, before: .seconds(5))
    }

    @Test(arguments: ["paused", "needs_attention", "failed", "running", "completed"])
    func givenIneligibleStatus_whenResumingWithExplicitConsent_thenRefusesCommand(status: String) {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        var run = inputRun()
        run.raw["status"] = .string(status)
        harness.sut.selectedRun = run
        harness.sut.instructions = "Continue"
        // when
        harness.sut.control("resume", allowOptionalReviewSkip: true)

        // then
        #expect(!run.canSkipOptionalReview)
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
    }

    @Test(arguments: ["hint", "decision", "delegation", "settling", "caller", "child", "answer", "command"])
    func givenMissingEligibilityOrAnswer_whenResumingWithExplicitConsent_thenRefusesCommand(condition: String) {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        var run = inputRun()
        harness.sut.instructions = "Continue"
        switch condition {
        case "hint": run.raw["optional_review_skip_available"] = .bool(false)
        case "decision": run.raw["input_decision_id"] = .string("")
        case "delegation": run.raw["execution_contract"] = nil
        case "settling": run.raw["settling"] = .bool(true)
        case "caller": run.raw["interaction_owner"] = .string("caller")
        case "child": run.raw["parent_workflow_run_id"] = .string("parent")
        case "answer": harness.sut.instructions = "  \n "
        default: break
        }
        harness.sut.selectedRun = run
        // when
        harness.sut.control(condition == "command" ? "recover" : "resume", allowOptionalReviewSkip: true)
        // then
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
    }
}
