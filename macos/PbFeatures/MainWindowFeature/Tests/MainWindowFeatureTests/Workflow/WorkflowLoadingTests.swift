import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - WorkflowLoadingTests

@MainActor
struct WorkflowLoadingTests {
    @Test func givenDelayedEditor_whenLoadingAndCompleted_thenSkeletonBlocksPlaceholderAndClears() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        // when
        vm.selectWorkflow(WorkflowRecord(raw: ["name": .string("saved")]))
        await waitUntil { useCase.pendingLoad != nil }
        // then
        #expect(vm.initialLoadingKind == "editor")
        #expect(!vm.canSave)
        useCase.finishLoad(["name": .string("saved"), "definition": .object(WorkflowVM.starterDefinition())])
        await waitUntil { vm.initialLoadingKind == nil }
        #expect(!vm.initialLoadFailed)
        #expect(vm.loadedName == "saved")
        useCase.finishAllValidations()
        vm.didDisappear()
    }

    @Test func givenRunLoadFailure_whenRefreshReturns_thenSkeletonEndsAndFailureIsVisible() async {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).command(.any, options: .any, positionals: .any).willThrow(WorkflowUIError.missingRun)
        harness.sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("missing")])
        harness.sut.initialLoadingKind = "run"
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.initialLoadingKind == nil)
        #expect(harness.sut.initialLoadFailed)
        #expect(harness.sut.errorText != nil)
    }

    @Test func givenRealNewCanvas_whenOpened_thenNoSkeletonOrInventedRunStatus() {
        // given
        let vm = WorkflowTests().makeVM().sut
        // when
        vm.newWorkflow()
        // then
        #expect(vm.initialLoadingKind == nil)
        #expect(!vm.initialLoadFailed)
        #expect(vm.selectedRun == nil)
        #expect(!vm.nodes.isEmpty)
    }

    @Test func givenLoadedRun_whenPolled_thenContentRemainsWithoutSkeleton() async {
        // given
        let harness = WorkflowTests().makeVM()
        let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "status": .string("running")]
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(raw)
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.initialLoadingKind == nil)
        #expect(!harness.sut.initialLoadFailed)
        #expect(harness.sut.selectedRun?.status == "running")
    }

    @Test func givenUnloadedRun_whenDisappearingThenReappearing_thenLoadingRearmsWithoutFakeStatus() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        useCase.delayRefresh = true
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        vm.initialLoadingKind = "run"
        // when
        vm.didDisappear()
        #expect(vm.initialLoadingKind == nil)
        vm.didAppear()
        await waitUntil { useCase.pendingRefresh != nil }
        // then
        #expect(vm.initialLoadingKind == "run")
        #expect(vm.selectedRun?.raw["status"] == nil)
        vm.didDisappear()
        useCase.finishRefresh()
        useCase.finishAllValidations()
    }

    @Test func givenPendingEditorRead_whenReappearing_thenNewReadCanCompleteBeforeOldRead() async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        vm.selectWorkflow(WorkflowRecord(raw: ["name": .string("saved")]))
        await waitUntil { useCase.pendingLoad != nil }
        let oldRead = try #require(useCase.pendingLoad)
        useCase.pendingLoad = nil
        // when
        vm.didDisappear()
        vm.didAppear()
        await waitUntil { useCase.pendingLoad != nil }
        useCase.finishLoad(["name": .string("saved"), "definition": .object(WorkflowVM.starterDefinition())])
        await waitUntil { vm.initialLoadingKind == nil }
        // then
        #expect(vm.loadedName == "saved")
        #expect(!vm.initialLoadFailed)
        oldRead.resume(returning: ["name": .string("stale")])
        #expect(vm.loadedName == "saved")
        vm.didDisappear()
        useCase.finishAllValidations()
    }

}
