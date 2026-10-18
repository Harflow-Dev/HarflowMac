import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - WorkflowPermissionPreviewTests

extension WorkflowTests {
    private func permissionPreview() -> [String: JSONValue] {
        ["preview_hash": .string("preview-one"), "owner_contracts": .object([
            "version": .string("native_owner_contract_v1"), "owners": .object([
                "root": .object(["name": .string("Workflow"), "candidates": .object([
                    "codex": .object([
                        "candidate": .object(["backend": .string("codex")]), "freedom": .string("write_in_repo"), "network": .bool(false),
                        "nodes": .array([
                            .object(["workflow_id": .string("root"), "node_id": .string("work"), "title": .string("Implementation")]),
                            .object(["workflow_id": .string("root"), "node_id": .string("review"), "title": .string("Review"),
                                     "fallback_reason": .string("Different harness")])
                        ]),
                        "contributing_nodes": .array([.object(["workflow_id": .string("root"), "node_id": .string("work")])])
                    ])
                ])])
            ])
        ])]
    }

    @Test func givenPinnedOwnerContract_whenReadingPermissions_thenOnlyNativeContributorsAreNamed() throws {
        // given
        let response = permissionPreview()
        // when
        let preview = try #require(WorkflowPermissionPreview(response))
        let candidate = try #require(preview.permissions.candidates.first)
        // then
        #expect(candidate.access == "Write in repository")
        #expect(candidate.network == "Requested off")
        #expect(candidate.contributingNodes == ["Implementation"])
        #expect(candidate.fallbacks == ["Review: Different harness"])
        #expect(WorkflowRunModel(raw: [:]).orchestratorPermissions == nil)
        #expect(WorkflowPermissionPreview(["preview_hash": .string("incomplete")]) == nil)
    }

    @Test func givenMixedWorkerCandidates_whenMappingPermissions_thenCandidateIdentityAndFallbackLabelsRemainDistinct() throws {
        // given
        let native: [String: JSONValue] = ["backend": .string("codex"), "model": .string("gpt")]
        let headless: [String: JSONValue] = ["backend": .string("claude"), "model": .string("opus")]
        let base: [String: JSONValue] = ["workflow_id": .string("root"), "node_id": .string("work"), "title": .string("Implementation")]
        var primary = base
        primary["candidate"] = .object(headless)
        primary["candidate_position"] = .number(0)
        primary["fallback_reason"] = .string("Different harness")
        var fallback = base
        fallback["candidate"] = .object(native)
        fallback["candidate_position"] = .number(1)
        var second = primary
        second["candidate_position"] = .number(2)
        var contributor = fallback
        contributor.removeValue(forKey: "title")
        var response = permissionPreview()
        var contracts = try #require(response["owner_contracts"]?.objectValue)
        contracts["owners"] = .object(["root": .object([
            "name": .string("Workflow"), "candidates": .object(["codex": .object([
                "candidate": .object(native), "freedom": .string("write_in_repo"), "network": .bool(false),
                "nodes": .array([.object(primary), .object(fallback), .object(second), .object(fallback)]),
                "contributing_nodes": .array([.object(contributor)])
            ])])
        ])])
        response["owner_contracts"] = .object(contracts)
        // when
        let preview = try #require(WorkflowPermissionPreview(response))
        let candidate = try #require(preview.permissions.candidates.first)
        // then
        #expect(candidate.contributingNodes == ["Implementation"])
        #expect(candidate.fallbacks == [
            "Implementation · primary · claude · opus: Different harness",
            "Implementation · fallback 2 · claude · opus: Different harness"
        ])
    }

    @Test func givenValidatedLaunchPreview_whenSettingsChange_thenRunIsDisabledUntilFreshPreview() async throws {
        // given
        let harness = makeVM()
        let vm = harness.sut
        let response = permissionPreview()
        given(harness.useCase).command(.value("preview"), options: .any, positionals: .any).willReturn(response)
        vm.definition = WorkflowVM.starterDefinition()
        vm.loadedName = "Workflow"
        vm.name = "Workflow"
        vm.savedDefinition = vm.definition
        vm.repo = "/tmp"
        // when
        vm.prepareLaunch()
        try await waitUntil { vm.canStartWithPreview }
        vm.overrideOrchestrator = true
        // then
        #expect(!vm.canStartWithPreview)
        #expect(vm.launchPreview == nil)
        try await waitUntil { vm.canStartWithPreview }
        vm.showsRunSheet = false
        #expect(!vm.canStartWithPreview)
        #expect(vm.launchPreview == nil)
    }

    @Test func givenValidatedLaunchPreview_whenEditingTaskPrompt_thenPermissionPreviewRemainsReadyWithoutAnotherRequest() async throws {
        // given
        let harness = makeVM()
        let vm = harness.sut
        given(harness.useCase).command(.value("preview"), options: .any, positionals: .any).willReturn(permissionPreview())
        vm.definition = WorkflowVM.starterDefinition()
        vm.loadedName = "Workflow"
        vm.name = "Workflow"
        vm.savedDefinition = vm.definition
        vm.repo = "/tmp"
        vm.prompt = "Initial task"
        vm.prepareLaunch()
        try await waitUntil { vm.canStartWithPreview }
        let requestID = vm.launchPreviewID
        let hash = vm.launchPreview?.hash
        // when
        vm.prompt = "Updated task"
        vm.prompt = "Updated task with more detail"
        // then
        #expect(vm.launchPreviewID == requestID)
        #expect(vm.launchPreview?.hash == hash)
        #expect(vm.canStartWithPreview)
        #expect(vm.launchPreviewMessage == nil)
        verify(harness.useCase).command(.value("preview"), options: .any, positionals: .any).called(1)
        vm.showsRunSheet = false
    }

    @Test func givenValidatedLaunchPreview_whenRecommittingUnchangedSettings_thenPreviewStaysReadyUntilRepositoryChanges() async throws {
        // given
        let harness = makeVM()
        let vm = harness.sut
        given(harness.useCase).command(.value("preview"), options: .any, positionals: .any).willReturn(permissionPreview())
        vm.definition = WorkflowVM.starterDefinition()
        vm.loadedName = "Workflow"
        vm.name = "Workflow"
        vm.savedDefinition = vm.definition
        vm.repo = "/tmp"
        vm.prepareLaunch()
        try await waitUntil { vm.canStartWithPreview }
        let requestID = vm.launchPreviewID
        let hash = vm.launchPreview?.hash
        let repository = vm.repo
        let name = vm.loadedName
        let definition = vm.savedDefinition
        let agent = vm.launchAgent
        let override = vm.overrideOrchestrator
        let showsSheet = vm.showsRunSheet
        // when
        vm.repo = repository
        vm.loadedName = name
        vm.savedDefinition = definition
        vm.launchAgent = agent
        vm.overrideOrchestrator = override
        vm.showsRunSheet = showsSheet
        // then
        #expect(vm.launchPreviewID == requestID)
        #expect(vm.launchPreview?.hash == hash)
        #expect(vm.canStartWithPreview)
        verify(harness.useCase).command(.value("preview"), options: .any, positionals: .any).called(1)
        vm.repo = "/tmp/another-repository"
        #expect(vm.launchPreviewID != requestID)
        #expect(vm.launchPreview == nil)
        #expect(!vm.canStartWithPreview)
        vm.showsRunSheet = false
    }

    @Test func givenUnpreviewedLaunch_whenStarting_thenNoRunIsDispatched() {
        // given
        let vm = makeVM().sut
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "Workflow"
        vm.loadedName = "Workflow"
        vm.savedDefinition = vm.definition
        // when
        vm.start()
        // then
        #expect(!vm.isBusy)
        #expect(vm.selectedRun == nil)
        #expect(vm.errorText == "Wait for the orchestrator permission preview before running.")
    }
}
