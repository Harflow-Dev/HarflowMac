import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import PbTestUtilities
import Testing

// MARK: - WorkflowTests agent editing

extension WorkflowTests {
    @Test func givenBuilderPublishingDrafts_whenMapped_thenSourceIsInitialAndLatestPreviewDoesNotMutateEditor() throws {
        // given
        let vm = makeVM().sut
        let source = try fixture("definition")
        vm.definition = source
        var raw: [String: JSONValue] = ["kind": .string("builder"), "editing_definition": .object(source)]
        let initial = WorkflowRunModel(raw: raw)
        var draft = source
        draft["max_parallel"] = .number(8)
        raw["builder_draft"] = .object(draft)
        raw["draft_revision"] = .number(2)
        raw["activations"] = .array([.object(["role": .string("builder"), "tasks": .array([.object(["task_id": .string("agent")])])])])
        // when
        vm.selectedRun = WorkflowRunModel(raw: raw)
        // then
        #expect(initial.definition == source)
        #expect(vm.selectedRun?.definition == draft)
        #expect(vm.selectedRun?.builderDraftRevision == 2)
        #expect(vm.selectedRun?.builderTaskID == "agent")
        #expect(vm.definition == source)
    }

    @Test func givenCreatedWorkflowFollowup_whenApplyingProposal_thenUsesNewDraftAndOriginalSavedRevision() throws {
        // given
        let vm = makeVM().sut
        let original = try fixture("definition")
        var refined = original
        refined["max_parallel"] = .number(9)
        let run = WorkflowRunModel(raw: ["kind": .string("builder"), "builder_followup": .bool(true),
                                        "workflow_run_id": .string("followup"), "workflow_name": .string("created"),
                                        "status": .string("completed"), "builder_draft": .object(refined),
                                        "generated_definition": .object(refined), "source_name": .string("created"),
                                        "source_revision": .number(1), "source_saved_definition": .object(original)])
        vm.selectedRun = run
        // when
        vm.applyAgentProposal()
        // then
        #expect(run.isBuilderProposal)
        #expect(vm.definition["max_parallel"] == .number(9))
        #expect(vm.revision == 1)
        #expect(vm.savedDefinition == original)
        #expect(vm.loadedName == "created")
        #expect(vm.selectedRun == nil)
    }

    @Test(arguments: ["", "/tmp/repo"])
    func givenPlacedUnsavedCanvas_whenBuilderStartsThenCanvasChanges_thenCapturedInputIsSentAndNewEditsSurvive(_ repo: String) async throws {
        // given
        let useCase = RecordingWorkflowBuilderUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.definition = try fixture("definition")
        vm.name = "current"
        vm.repo = repo
        vm.prompt = "add review"
        vm.isRefining = true
        let expected = vm.effectiveDefinition
        // when
        vm.generate()
        await waitUntil { useCase.pending != nil }
        #expect(useCase.options.contains { $0.hasPrefix("--repo=") } == !repo.isEmpty)
        let input = try #require(useCase.options.first { $0.hasPrefix("--definition-json=") })
        let encoded = String(input.dropFirst("--definition-json=".count))
        #expect(JSONValue.parse(Data(encoded.utf8))?.objectValue == expected)
        vm.definition["max_parallel"] = .number(8)
        let newer = vm.definition
        useCase.pending?.resume(returning: ["workflow_run_id": .string("proposal")])
        useCase.pending = nil
        await waitUntil { !vm.isBusy }
        // then
        #expect(vm.definition == newer)
        #expect(vm.selectedRun == nil)
        #expect(vm.errorText?.contains("canvas changed") == true)
    }

    @Test func givenUnsavedPlacedCanvas_whenApplyingProposal_thenBaselineAndRevisionArePreserved() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.name = "placed"
        vm.loadedName = "placed"
        vm.revision = 7
        vm.savedDefinition = ["name": .string("placed")]
        let baseline = vm.savedDefinition
        vm.refinementContext = WorkflowRefinementContext(draftID: vm.draftID, loadID: vm.editorLoadID,
                                                        definition: vm.definition, name: vm.name, loadedName: vm.loadedName,
                                                        revision: vm.revision, baseline: baseline, runID: "proposal")
        var proposed = vm.definition
        proposed["max_parallel"] = .number(2)
        proposed["revision"] = .number(999)
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("proposal"), "status": .string("completed"),
                                               "editing_definition": .object(vm.definition), "generated_definition": .object(proposed)])
        // when
        vm.applyAgentProposal()
        // then
        #expect(vm.definition["max_parallel"] == .number(2))
        #expect(vm.definition["revision"] == nil)
        #expect(vm.revision == 7)
        #expect(vm.savedDefinition == baseline)
        #expect(vm.loadedName == "placed")
        #expect(vm.selectedRun == nil)
        #expect(vm.isEditing)
    }

    @Test func givenProposalForOlderCanvas_whenEditsChange_thenApplyPreservesNewEditsAndExplainsConflict() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.name = "placed"
        vm.refinementContext = WorkflowRefinementContext(draftID: vm.draftID, loadID: vm.editorLoadID,
                                                        definition: vm.definition, name: vm.name, loadedName: "",
                                                        revision: 0, baseline: [:], runID: "proposal")
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("proposal"), "status": .string("completed"),
                                               "editing_definition": .object(vm.definition), "generated_definition": .object(vm.definition)])
        vm.definition["max_parallel"] = .number(8)
        let current = vm.definition
        // when
        vm.applyAgentProposal()
        vm.returnToCanvas()
        // then
        #expect(vm.definition == current)
        #expect(vm.errorText?.contains("canvas changed") == true)
        #expect(vm.selectedRun == nil)
    }

    @Test(arguments: ["identity", "load", "revision", "baseline", "saved-name"])
    func givenPendingProposal_whenSourceMetadataChanges_thenApplyRejectsTheStaleProposal(_ change: String) throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.name = "placed"
        vm.refinementContext = WorkflowRefinementContext(draftID: vm.draftID, loadID: vm.editorLoadID,
                                                        definition: vm.definition, name: vm.name, loadedName: "",
                                                        revision: 0, baseline: [:], runID: "proposal")
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("proposal"), "status": .string("completed"),
                                               "editing_definition": .object(vm.definition), "generated_definition": .object([:])])
        // when
        switch change {
        case "identity": vm.draftID = UUID()
        case "load": vm.editorLoadID = UUID()
        case "revision": vm.revision = 9
        case "baseline": vm.savedDefinition = ["name": .string("new")]
        default: vm.loadedName = "new"
        }
        let before = vm.definition
        vm.applyAgentProposal()
        // then
        #expect(vm.definition == before)
        #expect(vm.selectedRun != nil)
        #expect(vm.errorText != nil)
    }

    @Test func givenHistoricalProposal_whenApplied_thenOriginalSavedRevisionAndBaselineAreUsed() throws {
        // given
        let vm = makeVM().sut
        let proposal = try fixture("definition")
        let baseline: [String: JSONValue] = ["name": .string("original")]
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("history"), "workflow_name": .string("original"),
                                               "status": .string("completed"), "editing_definition": .object(proposal),
                                               "generated_definition": .object(proposal), "source_name": .string("original"),
                                               "source_revision": .number(4), "source_saved_definition": .object(baseline)])
        // when
        vm.applyAgentProposal()
        // then
        #expect(vm.name == "original")
        #expect(vm.loadedName == "original")
        #expect(vm.revision == 4)
        #expect(vm.savedDefinition == baseline)
        #expect(vm.appliedProposalIDs == ["history"])
    }
}

// MARK: - RecordingWorkflowBuilderUseCase

@MainActor
private final class RecordingWorkflowBuilderUseCase: WorkflowUseCase, @unchecked Sendable {
    var options: [String] = []
    var pending: CheckedContinuation<[String: JSONValue], Never>?
    var backendIDs: [String] { ["codex"] }
    func command(_ command: String, options: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        guard command == "build" else { return [:] }
        self.options = options
        return await withCheckedContinuation { pending = $0 }
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { ["valid": .bool(true)] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] { [:] }
    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
