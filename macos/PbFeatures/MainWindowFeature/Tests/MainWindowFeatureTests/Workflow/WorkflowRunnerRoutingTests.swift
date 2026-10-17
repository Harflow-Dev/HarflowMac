import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - WorkflowRunnerRoutingTests

@MainActor
@Suite struct WorkflowRunnerRoutingTests {
    private func makeRunner() throws -> (WorkflowVM, MockWorkflowUseCase, MockWorkflowRouting) {
        let useCase = MockWorkflowUseCase()
        let routing = MockWorkflowRouting()
        given(useCase).refreshTasks().willReturn()
        given(routing).openWorkflowRun(id: .any).willReturn()
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowRunnerDraftStore(), routesStartedRun: true,
                                    visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.validationSuspended = true
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "Saved workflow"
        vm.loadedName = vm.name
        vm.savedDefinition = vm.definition
        vm.repo = "/tmp"
        vm.prompt = "Implement requested change"
        vm.prepareLaunch()
        vm.launchPreviewTask?.cancel()
        vm.launchPreviewMessage = nil
        vm.launchPreview = try #require(WorkflowPermissionPreview([
            "preview_hash": .string("verified-preview"),
            "owner_contracts": .object([
                "version": .string("native_owner_contract_v1"),
                "owners": .object(["root": .object([
                    "name": .string("Saved workflow"),
                    "candidates": .object(["codex": .object([
                        "candidate": .object(["backend": .string("codex")]),
                        "freedom": .string("write_in_repo"), "network": .bool(false),
                        "nodes": .array([]), "contributing_nodes": .array([])
                    ])])
                ])])
            ])
        ]))
        return (vm, useCase, routing)
    }

    @Test func givenMenuRunner_whenStartSucceeds_thenExactNewRunIsRoutedAndSheetCloses() async throws {
        // given
        let (vm, useCase, routing) = try makeRunner()
        given(useCase)
.command(.value("start"), options: .any, positionals: .value(["Saved workflow"]))
            .willReturn(["workflow_run_id": .string("created-run")])
        // when
        vm.start()
        try await waitUntil { !vm.isBusy }
        // then
        #expect(vm.selectedRun?.id == "created-run")
        #expect(!vm.showsRunSheet)
        verify(routing).openWorkflowRun(id: .value("created-run")).called(1)
        verify(useCase).refreshTasks().called(1)
        vm.didDisappear()
    }

    @Test(arguments: ["  Verify all states.\nPreserve whitespace.  ", " \n "])
    func givenLaunchGoal_whenStarting_thenPreservesSuppliedTextOrOmitsBlank(_ goal: String) async throws {
        // given
        let (vm, useCase, _) = try makeRunner()
        defer { vm.didDisappear() }
        vm.goal = goal
        let expected = (goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--goal=\(goal)"])
            + vm.launchPreviewOptions + ["--monitor", "--prompt=\(vm.prompt)", "--expected-preview-hash=verified-preview"]
        given(useCase)
.command(.value("start"), options: .any, positionals: .any)
            .willReturn(["workflow_run_id": .string("created-run")])
        // when
        vm.start()
        // then
        await verify(useCase)
.command(.value("start"), options: .value(expected), positionals: .value(["Saved workflow"]))
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenMenuRunner_whenStartFails_thenNoRunIsRoutedAndSheetStaysOpen() async throws {
        // given
        let (vm, useCase, routing) = try makeRunner()
        given(useCase).command(.value("start"), options: .any, positionals: .any).willThrow(WorkflowUIError.missingRun)
        // when
        vm.start()
        try await waitUntil { !vm.isBusy }
        // then
        #expect(vm.selectedRun == nil)
        #expect(vm.showsRunSheet)
        #expect(vm.errorText != nil)
        verify(routing).openWorkflowRun(id: .any).called(0)
        vm.didDisappear()
    }
}
