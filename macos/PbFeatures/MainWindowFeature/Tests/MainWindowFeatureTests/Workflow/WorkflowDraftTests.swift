import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - WorkflowDraftTests

@MainActor
@Suite struct WorkflowDraftTests {
    func store() -> WorkflowDraftStore {
        WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func vm(store: any WorkflowDraftStoring) -> WorkflowVM {
        let useCase = MockWorkflowUseCase()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(false)])
        given(useCase).backendIDs.willReturn(["codex"])
        return WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store)
    }

    @Test func givenUnchangedSavedWorkflow_whenEditingNameInstructionsOrPosition_thenSaveReflectsDirtyState() {
        // given
        let sut = vm(store: store())
        sut.newWorkflow()
        sut.name = "Saved workflow"
        sut.loadedName = sut.name
        sut.savedDefinition = sut.definition
        // when / then
        #expect(!sut.canSave)
        sut.name = "Renamed workflow"
        #expect(sut.canSave)
        sut.name = sut.loadedName
        #expect(!sut.canSave)
        sut.updateNode("planning", key: "instructions", value: .string("Changed instructions"))
        #expect(sut.canSave)
        sut.definition = sut.savedDefinition
        #expect(!sut.canSave)
        sut.moveNode("start", to: CGPoint(x: 200, y: 200))
        #expect(sut.canSave)
        sut.savedDefinition = sut.definition
        #expect(!sut.canSave)
        sut.newWorkflow()
        #expect(sut.canSave)
    }

    @Test(arguments: ["absent", "false", "true"])
    func givenSavedOptionalFlag_whenToggledAndReverted_thenSaveReflectsBehavioralChange(baseline: String) {
        // given
        let sut = vm(store: store())
        sut.newWorkflow()
        sut.name = "Saved workflow"
        sut.loadedName = sut.name
        if baseline != "absent" { sut.updateNode("planning", key: "optional", value: .bool(baseline == "true")) }
        sut.savedDefinition = sut.definition
        #expect(!sut.canSave)
        // when
        sut.updateNode("planning", key: "optional", value: .bool(baseline != "true"))
        // then
        #expect(sut.hasUnsavedChanges)
        #expect(sut.canSave)
        // when
        sut.updateNode("planning", key: "optional", value: .bool(baseline == "true"))
        // then
        #expect(!sut.hasUnsavedChanges)
        #expect(!sut.canSave)
        // Other fields keep exact comparison semantics.
        sut.updateNode("planning", key: "instructions", value: .string("Different instructions"))
        #expect(sut.hasUnsavedChanges)
    }

    @Test func givenIncompleteNewDraft_whenNavigatingAndRecreatingEditor_thenNameAndGraphSurvive() throws {
        // given
        let store = store()
        let first = vm(store: store)
        first.newWorkflow()
        first.name = "Work in progress"
        first.definition["connections"] = .array([])
        first.addNode("review")
        let edited = first.definition
        // when
        first.didDisappear()
        let reopened = vm(store: store)
        reopened.prepareEditor(name: nil)
        // then
        #expect(reopened.name == "Work in progress")
        #expect(reopened.definition == edited)
        #expect(reopened.revision == 0)
        #expect(reopened.hasUnsavedChanges)
    }

    @Test func givenSavedDraftWithOriginalRevision_whenRestored_thenBaselineDoesNotAdvance() throws {
        // given
        let store = store()
        let baseline = WorkflowVM.starterDefinition()
        var edited = baseline
        edited["description"] = .string("Local instructions")
        try store.save(["name": .string("Renamed workflow"), "loaded_name": .string("Original"),
                        "revision": .number(7), "definition": .object(edited), "saved_definition": .object(baseline)], key: "saved:Original")
        // when
        let reopened = vm(store: store)
        reopened.selectWorkflow(WorkflowRecord(raw: ["name": .string("Original")]))
        // then
        #expect(reopened.name == "Renamed workflow")
        #expect(reopened.loadedName == "Original")
        #expect(reopened.revision == 7)
        #expect(reopened.savedDefinition == baseline)
        #expect(reopened.definition == edited)
        #expect(reopened.hasUnsavedChanges)
    }

    @Test func givenSavedWorkflowAndNameOnlyChange_whenFlushed_thenRenameRemainsADraft() throws {
        // given
        let store = store()
        let sut = vm(store: store)
        sut.draftKey = "saved:Original"
        sut.loadedName = "Original"
        sut.name = "Original"
        sut.definition = WorkflowVM.starterDefinition()
        sut.savedDefinition = sut.definition
        // when
        sut.name = "Better name"
        sut.persistDraft()
        // then
        #expect(sut.hasUnsavedChanges)
        #expect(try store.load(key: "saved:Original")?["name"]?.stringValue == "Better name")
    }

    @Test func givenCommittedDraft_whenFinishingSave_thenOnlyItsDraftIsRemoved() throws {
        // given
        let store = store()
        let sut = vm(store: store)
        sut.newWorkflow()
        sut.name = "Saved"
        sut.persistDraft()
        try store.save(["definition": .object([:])], key: "saved:Other")
        // when
        sut.loadedName = "Saved"
        sut.savedDefinition = sut.definition
        sut.finishDraftSave(previousKey: "new")
        // then
        #expect(try store.load(key: "new") == nil)
        #expect(try store.load(key: "saved:Saved") == nil)
        #expect(try store.load(key: "saved:Other") != nil)
    }

    @Test func givenAgentProposalApplied_whenEditorRecreated_thenApprovedChangesSurvive() throws {
        // given
        let store = store()
        let sut = vm(store: store)
        sut.newWorkflow()
        var proposal = sut.definition
        proposal["description"] = .string("Approved agent edit")
        sut.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("proposal"), "workflow_name": .string("Generated"),
                                                "kind": .string("builder"), "status": .string("completed"),
                                                "builder_followup": .bool(true), "generated_definition": .object(proposal)])
        // when
        sut.applyAgentProposal()
        let reopened = vm(store: store)
        reopened.newWorkflow()
        // then
        #expect(reopened.definition["description"]?.stringValue == "Approved agent edit")
    }

    @Test(arguments: [false, true])
    func givenSaveInFlight_whenLeavingEditor_thenDurableDraftReconcilesOnlyCommittedSnapshot(newerEdits: Bool) async throws {
        // given
        let store = store()
        let useCase = ControlledWorkflowValidationUseCase()
        let sut = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store)
        sut.newWorkflow()
        sut.name = "Saved later"
        sut.validatedDefinition = sut.effectiveDefinition
        let submitted = sut.effectiveDefinition
        // when
        sut.save()
        await waitUntil { !useCase.savedRequests.isEmpty }
        if newerEdits { sut.definition["description"] = .string("Newer local changes") }
        sut.didDisappear()
        var saved = submitted
        saved["revision"] = .number(1)
        useCase.finishSave(saved)
        await waitUntil { !sut.isBusy }
        // then
        #expect(try store.load(key: "new") == nil)
        if newerEdits {
            let draft = try #require(try store.load(key: "saved:Saved later"))
            #expect(draft["definition"]?["description"]?.stringValue == "Newer local changes")
            #expect(draft["revision"]?.intValue == 1)
            #expect(draft["saved_definition"]?.objectValue == saved)
        } else {
            #expect(try store.load(key: "saved:Saved later") == nil)
        }
        useCase.finishAllValidations()
    }

    @Test func givenOtherNewDraft_whenDuplicatingSavedWorkflow_thenExistingDraftIsPreserved() throws {
        // given
        let store = store()
        let original: [String: JSONValue] = ["draft_id": .string(UUID().uuidString), "name": .string("Unfinished new workflow"), "definition": .object([:])]
        try store.save(original, key: "new")
        let sut = vm(store: store)
        sut.loadedName = "Saved"
        sut.name = "Saved"
        sut.draftKey = "saved:Saved"
        // when
        sut.duplicate()
        // then
        #expect(try store.load(key: "new") == original)
        #expect(sut.name == "Saved")
        #expect(sut.errorText != nil)
    }

    @Test func givenEditorLoadInFlight_whenNavigatingAway_thenNoPlaceholderDraftIsWritten() async throws {
        // given
        let store = store()
        let useCase = ControlledWorkflowValidationUseCase()
        let sut = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store)
        // when
        sut.selectWorkflow(WorkflowRecord(raw: ["name": .string("Original")]))
        await waitUntil { useCase.pendingLoad != nil }
        sut.didDisappear()
        useCase.finishLoad(["name": .string("Original"), "revision": .number(7), "nodes": .array([])])
        await waitUntil { !sut.isBusy }
        // then
        #expect(try store.load(key: "saved:Original") == nil)
        useCase.finishAllValidations()
    }

    @Test func givenDraftWriteFailure_whenSaveRetainsNewerEdits_thenOriginalDraftSurvivesAndFailureIsVisible() throws {
        // given
        let backing = store()
        let failing = FailingWorkflowDraftStore(backing: backing)
        let sut = vm(store: failing)
        sut.newWorkflow()
        sut.name = "Saved"
        sut.persistDraft()
        let original = try backing.load(key: "new")
        sut.loadedName = "Saved"
        sut.savedDefinition = sut.definition
        sut.definition["description"] = .string("Newer edits")
        failing.failWrites = true
        // when
        sut.finishDraftSave(previousKey: "new")
        // then
        #expect(try backing.load(key: "new") == original)
        #expect(sut.errorText?.contains("Unable to preserve workflow draft") == true)
    }

    @Test func givenReopenedEditorBeforeLateSaveCompletes_whenEditing_thenSavedBaselineCannotBeOverwritten() async throws {
        // given
        let store = store()
        let useCase = ControlledWorkflowValidationUseCase()
        let sut = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store)
        sut.newWorkflow()
        sut.name = "Saved later"
        sut.validatedDefinition = sut.effectiveDefinition
        let submitted = sut.effectiveDefinition
        sut.save()
        await waitUntil { !useCase.savedRequests.isEmpty }
        sut.didDisappear()
        let reopened = vm(store: store)
        reopened.newWorkflow()
        // when
        var saved = submitted
        saved["revision"] = .number(1)
        useCase.finishSave(saved)
        await waitUntil { !sut.isBusy }
        reopened.definition["description"] = .string("Edited in reopened window")
        reopened.persistDraft()
        // then
        let draft = try #require(try store.load(key: "saved:Saved later"))
        #expect(draft["revision"]?.intValue == 1)
        #expect(draft["saved_definition"]?.objectValue == saved)
        #expect(draft["definition"]?["description"]?.stringValue == "Edited in reopened window")
        #expect(try store.load(key: "new") == nil)
        useCase.finishAllValidations()
    }

}

@MainActor
private final class FailingWorkflowDraftStore: WorkflowDraftStoring {
    let backing: WorkflowDraftStore
    var failWrites = false
    init(backing: WorkflowDraftStore) { self.backing = backing }
    func load(key: String) throws -> [String: JSONValue]? { try backing.load(key: key) }
    func remove(key: String) throws { try backing.remove(key: key) }
    func save(_ draft: [String: JSONValue], key: String) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try backing.save(draft, key: key)
    }
}
