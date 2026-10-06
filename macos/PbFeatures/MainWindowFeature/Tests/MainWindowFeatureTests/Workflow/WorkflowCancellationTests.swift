import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

@MainActor
@Suite struct WorkflowCancellationTests {
    @Test func givenIdleCallerOwnedRun_whenCancelled_thenHumanFlagSentAndOwnershipPreserved() async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "status": .string("needs_input"),
            "interaction_owner": .string("caller"), "can_cancel_from_monitor": .bool(true)])
        harness.sut.instructions = "Unsaved caller answer"
        // when
        harness.sut.control("cancel")
        harness.sut.control("cancel")
        // then
        await verify(harness.useCase)
.command(.value("cancel"), options: .value(["--monitor"]), positionals: .value(["run"]))
            .calledEventually(1, before: .seconds(5))
        #expect(harness.sut.instructions == "Unsaved caller answer")
        #expect(harness.sut.selectedRun?.allowsMonitorControl == false)
    }

    @Test func givenCallerOwnedActiveRun_whenCancelled_thenCommandRefused() {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"), "status": .string("running"),
            "interaction_owner": .string("caller"), "can_cancel_from_monitor": .bool(false)])
        // when
        harness.sut.control("cancel")
        // then
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
    }

    @Test(arguments: ["completed", "failed", "cancelled", "cancelling"])
    func givenSettledOrCancellingRun_whenCapabilityIsStale_thenCancelHidden(status: String) {
        // given
        let run = WorkflowRunModel(raw: ["status": .string(status), "interaction_owner": .string("monitor"),
            "can_cancel_from_monitor": .bool(true)])
        // then
        #expect(!run.canCancelFromMonitor)
    }

    @Test func givenChildRun_whenCancellationConsidered_thenRootIsExplicit() {
        // given
        let run = WorkflowRunModel(raw: ["workflow_run_id": .string("child"), "status": .string("paused"),
            "root_workflow_run_id": .string("root"), "parent_workflow_run_id": .string("parent"),
            "can_cancel_from_monitor": .bool(true)])
        // then
        #expect(!run.canCancelFromMonitor)
        #expect(run.rootRunID == "root")
    }
}
