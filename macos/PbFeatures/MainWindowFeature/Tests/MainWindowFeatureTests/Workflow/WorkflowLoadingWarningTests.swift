import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
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

    @Test func givenLoadedRun_whenCatalogPreparing_thenPreservesRunAndDoesNotNotify() async {
        // given
        let harness = WorkflowTests().makeVM()
        let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "status": .string("running")]
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([
            "catalog_state": .object(["status": .string("preparing"), "source": .string("workflow_catalog")])
        ])
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.selectedRun?.raw == raw)
        #expect(harness.sut.errorText == nil)
    }

    @Test func givenDurableOutcome_whenAssigned_thenDoesNotBecomeLoadingIncident() {
        // given
        let harness = WorkflowTests().makeVM()
        var events: [ViewEvent] = []
        let subscription = harness.sut.objectDidPublishViewEvent.publisher.sink { events.append($0) }
        // when
        harness.sut.errorText = "Unable to preserve workflow draft"
        // then
        #expect(events.isEmpty)
        #expect(harness.sut.readFailureText == nil)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenBlockedRead_whenReady_thenClearsItsFailureAndResolvesSameSource() async {
        // given
        final class Responses { var ready = false }
        let box = Responses()
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        given(harness.useCase).command(.any, options: .any, positionals: .any).willProduce { _, _, _ in
            box.ready ? ["workflow_run_id": .string("run"), "status": .string("running")]
                : ["catalog_state": .object(["status": .string("blocked"), "reason": .string("Record too large")])]
        }
        await harness.sut.refresh()
        #expect(harness.sut.readFailures["workflow-run:run"] == "Record too large")
        // when
        box.ready = true
        await harness.sut.refresh()
        // then
        #expect(harness.sut.errorText == nil)
        #expect(harness.sut.readFailures.isEmpty)
        #expect(harness.sut.readFailureText == nil)
    }

    @Test func givenBlockedSavedEditor_whenReloaded_thenRetriesGetAndResolvesCapturedSource() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        vm.selectWorkflow(WorkflowRecord(raw: ["name": .string("saved")]))
        await waitUntil { useCase.pendingLoad != nil }
        useCase.finishLoad(["catalog_state": .object(["status": .string("blocked"), "reason": .string("Record too large")])])
        await waitUntil { vm.initialLoadFailed }
        #expect(vm.draftKey == nil)
        #expect(vm.readFailures["workflow-editor:saved"] == "Record too large")
        // when
        vm.retryReadFailure()
        await waitUntil { useCase.pendingLoad != nil }
        useCase.finishLoad(["name": .string("saved"), "definition": .object(WorkflowVM.starterDefinition())])
        await waitUntil { vm.initialLoadingKind == nil }
        // then
        #expect(vm.name == "saved")
        #expect(!vm.initialLoadFailed)
        #expect(vm.readFailures.isEmpty)
        #expect(vm.errorText == nil)
    }

    @Test(arguments: ["", "other"])
    func givenMalformedReadyRun_whenInitiallyLoading_thenPreservesIdentityAndSettlesWithReadFailure(responseID: String) async {
        // given
        let harness = WorkflowTests().makeVM()
        let placeholder: [String: JSONValue] = ["workflow_run_id": .string("run")]
        harness.sut.selectedRun = WorkflowRunModel(raw: placeholder)
        harness.sut.initialLoadingKind = "run"
        var response: [String: JSONValue] = ["status": .string("running")]
        if !responseID.isEmpty { response["workflow_run_id"] = .string(responseID) }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(response)
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.selectedRun?.raw == placeholder)
        #expect(harness.sut.initialLoadingKind == nil)
        #expect(harness.sut.initialLoadFailed)
        #expect(harness.sut.readFailures["workflow-run:run"] != nil)
        #expect(harness.sut.readFailureText != nil)
    }

    @Test(arguments: ["", "other"])
    func givenMalformedReadyRun_whenRefreshingLoadedSnapshot_thenKeepsPriorDetails(responseID: String) async {
        // given
        let harness = WorkflowTests().makeVM()
        let loaded: [String: JSONValue] = ["workflow_run_id": .string("run"), "status": .string("running")]
        harness.sut.selectedRun = WorkflowRunModel(raw: loaded)
        var response: [String: JSONValue] = ["status": .string("completed")]
        if !responseID.isEmpty { response["workflow_run_id"] = .string(responseID) }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(response)
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.selectedRun?.raw == loaded)
        #expect(!harness.sut.initialLoadFailed)
        #expect(harness.sut.readFailures["workflow-run:run"] != nil)
    }

    @Test func givenReadyRunWithoutStatus_whenLoading_thenPreservesPlaceholderAndReportsFailure() async {
        // given
        let harness = WorkflowTests().makeVM()
        let placeholder: [String: JSONValue] = ["workflow_run_id": .string("run")]
        harness.sut.selectedRun = WorkflowRunModel(raw: placeholder)
        harness.sut.initialLoadingKind = "run"
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(placeholder)
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.selectedRun?.raw == placeholder)
        #expect(harness.sut.initialLoadingKind == nil)
        #expect(harness.sut.initialLoadFailed)
        #expect(harness.sut.readFailures["workflow-run:run"] != nil)
    }

}
