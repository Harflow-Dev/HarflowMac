import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowLoadingWarningTests

@MainActor
@Suite struct WorkflowLoadingWarningTests {
    @Test func givenStaleLoadingWarning_whenRefreshSucceeds_thenWarningClears() async {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        harness.sut.errorText = WorkflowRunPolling.staleDetailMessage
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(["workflow_run_id": .string("run"), "status": .string("running")])
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.errorText == nil)
    }

    @Test func givenExpiredSnapshotRefreshError_whenRefreshSucceeds_thenTransientErrorClears() async {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        harness.sut.refreshErrorText = "Invalid or expired Monitor snapshot cursor; refresh the workflow"
        harness.sut.errorText = harness.sut.refreshErrorText
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(["workflow_run_id": .string("run"), "status": .string("running")])
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.errorText == nil)
        #expect(harness.sut.refreshErrorText == nil)
    }

    @Test func givenUnrelatedError_whenRefreshSucceeds_thenErrorRemainsVisible() async {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        harness.sut.errorText = "Could not cancel the run"
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(["workflow_run_id": .string("run"), "status": .string("running")])
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.errorText == "Could not cancel the run")
    }
}
