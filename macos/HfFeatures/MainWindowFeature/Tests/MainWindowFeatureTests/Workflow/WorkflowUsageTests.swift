import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct WorkflowUsageTests {
    private func makeVM(routesStartedRun: Bool = false) -> (WorkflowVM, MockWorkflowUseCase) {
        let useCase = MockWorkflowUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockWorkflowRouting()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        given(useCase).recordAgentUsage(.any, acknowledgementID: .any).willReturn()
        given(useCase).refreshTasks().willReturn()
        given(routing).openWorkflowRun(id: .any).willReturn()
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: store, routesStartedRun: routesStartedRun,
                            visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        return (vm, useCase)
    }

    private func definition() throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "definition", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
    }

    private func preview(backend: String) throws -> WorkflowPermissionPreview {
        try #require(WorkflowPermissionPreview([
            "preview_hash": .string("hash"),
            "owner_contracts": .object([
                "version": .string("native_owner_contract_v1"),
                "owners": .object(["root": .object([
                    "name": .string("implement-review"),
                    "candidates": .object([backend: .object([
                        "candidate": .object(["backend": .string(backend)]),
                        "freedom": .string("write_in_repo"), "network": .bool(false),
                        "nodes": .array([]), "contributing_nodes": .array([])
                    ])])
                ])])
            ])
        ]))
    }

    @Test func givenUsageCounts_whenWorkflowBackendMenuReads_thenBackendRanksDeterministically() {
        // given
        let (vm, _) = makeVM()
        vm.agentUsageSnapshot = AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "claude", model: nil): 3])

        // then
        #expect(vm.backendIDs == ["claude", "codex"])
    }

    @Test func givenOverrideOrchestrator_whenWorkflowStarts_thenUsageCapturesOverrideAndRunID() async throws {
        // given
        let (vm, useCase) = makeVM(routesStartedRun: true)
        let raw = try definition()
        vm.validationSuspended = true
        vm.definition = raw; vm.savedDefinition = raw; vm.name = "implement-review"; vm.loadedName = "implement-review"
        vm.repo = "/tmp"; vm.showsRunSheet = true; vm.overrideOrchestrator = true
        vm.launchAgent = ["backend": .string("vibe"), "model": .string("fast")]
        vm.launchPreviewTask?.cancel()
        _ = await vm.qualification?.discover(.workflow(name: vm.loadedName, options: vm.launchPreviewOptions))
        vm.launchPreview = try preview(backend: "vibe"); vm.launchPreviewMessage = nil
        given(useCase)
.command(.value("start"), options: .any, positionals: .value(["implement-review"]), runtime: .any)
            .willReturn(["workflow_run_id": .string("run-1")])

        #expect(vm.canStartWithPreview)

        // when
        vm.start(); await waitUntil { !vm.isBusy }

        // then
        verify(useCase).command(.value("start"), options: .any, positionals: .value(["implement-review"]), runtime: .any).called(1)
        verify(useCase)
.recordAgentUsage(.value(AgentUsageIdentity(backend: "vibe", model: "fast")),
                                         acknowledgementID: .value("workflow:run-1"))
.called(1)
    }

    @Test func givenMissingWorkflowRunID_whenWorkflowStarts_thenUsageIsNotRecorded() async throws {
        // given
        let (vm, useCase) = makeVM(routesStartedRun: true)
        let raw = try definition()
        vm.validationSuspended = true
        vm.definition = raw; vm.savedDefinition = raw; vm.name = "implement-review"; vm.loadedName = "implement-review"
        vm.repo = "/tmp"; vm.showsRunSheet = true
        vm.launchPreviewTask?.cancel()
        _ = await vm.qualification?.discover(.workflow(name: vm.loadedName, options: vm.launchPreviewOptions))
        vm.launchPreview = try preview(backend: "codex")
        vm.launchPreviewMessage = nil
        given(useCase)
.command(.value("start"), options: .any, positionals: .value(["implement-review"]), runtime: .any)
            .willReturn([:])

        #expect(vm.canStartWithPreview)

        // when
        vm.start(); await waitUntil { !vm.isBusy }

        // then
        verify(useCase).command(.value("start"), options: .any, positionals: .value(["implement-review"]), runtime: .any).called(1)
        verify(useCase).recordAgentUsage(.any, acknowledgementID: .any).called(0)
        #expect(vm.errorText == WorkflowUIError.missingRun.errorDescription)
    }
}
