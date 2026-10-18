import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@Suite struct WorkflowGoalTests {
    @Test func givenLegacyRun_whenReadingGoal_thenDefaultsAreSafe() {
        // given
        let run = WorkflowRunModel(raw: [:])
        // when / then
        #expect(run.goal == nil)
        #expect(run.goalRevision == 0)
        #expect(run.goalHistory.isEmpty)
        #expect(!run.canReviseGoal)
    }

    @Test func givenGoalPayload_whenReadingGoal_thenPreservesTextAndBackendEligibility() {
        // given
        let goal = "  Compare the screen.\nPreserve spacing.  "
        let run = WorkflowRunModel(raw: [
            "goal": .string(goal), "goal_revision": .number(2),
            "status": .string("paused"), "interaction_owner": .string("monitor"), "can_revise_goal": .bool(true),
            "goal_history": .array([.object(["revision": .number(1), "goal": .string("Earlier goal")])]),
            "goal_assessment": .object(["revision": .number(2), "status": .string("unmet")]),
            "goal_revision_reason": .string("Waiting for workers to finish.")
        ])
        // when / then
        #expect(run.goal == goal)
        #expect(run.goalRevision == 2)
        #expect(run.goalHistory.count == 1)
        #expect(run.goalAssessment?["status"]?.stringValue == "unmet")
        #expect(run.canReviseGoal)
        #expect(run.goalRevisionReason == "Waiting for workers to finish.")
    }
}

@MainActor
struct WorkflowGoalRevisionTests {
    @Test func givenGoalRefreshSupersededByPolling_whenReadIsCancelled_thenDoesNotReportFailure() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willThrow(CancellationError())
        harness.sut.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string(String(repeating: "a", count: 32)), "status": .string("paused")
        ])
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.errorText == nil)
        #expect(harness.sut.readFailures.isEmpty)
    }

    @Test func givenEligibleRun_whenRevisingThenSelectionChanges_thenCapturesRunAndRevision() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        harness.sut.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("run"), "goal_revision": .number(3), "status": .string("paused"),
            "interaction_owner": .string("monitor"), "can_revise_goal": .bool(true)
        ])
        // when
        harness.sut.reviseGoal("  Verify\nall states  ", runID: "run", expectedRevision: 3)
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("other")])
        // then
        let options = ["--monitor", "--goal=  Verify\nall states  ", "--expected-revision=3"]
        await verify(harness.useCase)
.command(.value("revise-goal"), options: .value(options), positionals: .value(["run"]))
            .calledEventually(1, before: .seconds(5))
    }

    @Test(arguments: ["", " \n ", String(repeating: "é", count: 32_769)])
    func givenInvalidGoal_whenRevising_thenRejectsWithoutCommand(_ goal: String) {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("run"), "status": .string("paused"),
            "interaction_owner": .string("monitor"), "can_revise_goal": .bool(true)
        ])
        // when
        harness.sut.reviseGoal(goal, runID: "run", expectedRevision: 0)
        // then
        #expect(harness.sut.errorText != nil)
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
    }
}
