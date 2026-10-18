import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTestUtilities
import Testing

// MARK: - WorkflowConflictRecoveryTests

@MainActor
@Suite struct WorkflowConflictRecoveryTests {
    func makeVM(failRead: Bool = false, failSave: Bool = false) -> (WorkflowVM, WorkflowDraftStore, MockWorkflowUseCase) {
        let store = WorkflowDraftTests().store()
        let useCase = MockWorkflowUseCase()
        given(useCase).backendIDs.willReturn(["codex"])
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        if failRead {
            given(useCase).command(.value("get"), options: .any, positionals: .any).willThrow(WorkflowUIError.missingRun)
        } else {
            given(useCase).command(.value("get"), options: .any, positionals: .any).willReturn(current)
        }
        if failSave {
            given(useCase).save(name: .any, definition: .any, expectedRevision: .any, expectedWorkflowID: .any).willThrow(WorkflowUIError.missingRun)
        }
        let sut = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.draftPersistenceSuspended = true
        sut.name = "Saved"
        sut.loadedName = "Saved"
        sut.revision = 1
        sut.savedDefinition = baseline
        sut.definition = baseline.merging(["description": .string("unsaved")]) { _, new in new }
        sut.draftKey = "saved:Saved"
        sut.isEditing = true
        sut.draftPersistenceSuspended = false
        sut.persistDraft()
        return (sut, store, useCase)
    }

    var baseline: [String: JSONValue] { ["workflow_id": .string("identity"), "name": .string("Saved"), "nodes": .array([])] }
    var current: [String: JSONValue] { ["name": .string("Saved"), "revision": .number(2), "definition": .object(baseline)] }

    @Test func givenConflict_whenPreservingCopyAndReloading_thenCopyAndCurrentBaselineRemainEditable() async throws {
        // given
        let (sut, store, _) = makeVM()
        let edits = sut.definition
        sut.editorConflict = "Changed"
        let oldID = sut.draftID
        // when
        sut.preserveDraftAndReload()
        await waitUntil { sut.initialLoadingKind == nil }
        // then
        #expect(sut.definition == baseline)
        #expect(sut.revision == 2)
        #expect(sut.editorConflict == nil)
        #expect(sut.draftID != oldID)
        #expect(try store.load(key: "new")?["definition"] == .object(edits))
        #expect(try store.load(key: "saved:Saved") == nil)
        sut.definition["description"] = .string("reconciled")
        #expect(sut.canSave)
    }

    @Test func givenConflict_whenReloadFails_thenDurableCopyPreservesEdits() async throws {
        // given
        let (sut, store, _) = makeVM(failRead: true)
        let edits = sut.definition
        // when
        sut.preserveDraftAndReload()
        await waitUntil { sut.initialLoadingKind == nil }
        // then
        #expect(sut.initialLoadFailed)
        #expect(try store.load(key: "new")?["definition"] == .object(edits))
    }

    @Test func givenOccupiedCopySlot_whenRecovering_thenBothDraftsRemainUnchanged() throws {
        // given
        let (sut, store, _) = makeVM()
        let occupied: [String: JSONValue] = ["draft_id": .string(UUID().uuidString), "definition": .object(["description": .string("other")])]
        try store.save(occupied, key: "new")
        let edits = sut.definition
        // when
        sut.preserveDraftAndReload()
        // then
        #expect(sut.definition == edits)
        #expect(try store.load(key: "new") == occupied)
        #expect(try store.load(key: "saved:Saved")?["definition"] == .object(edits))
    }

    @Test func givenFailedCurrentRead_whenDiscarding_thenUnsavedDraftIsRetained() async throws {
        // given
        let (sut, store, _) = makeVM(failRead: true)
        let edits = sut.definition
        // when
        sut.discardChanges()
        await waitUntil { !sut.isBusy }
        // then
        #expect(sut.definition == edits)
        #expect(try store.load(key: "saved:Saved")?["definition"] == .object(edits))
        #expect(sut.errorText != nil)
    }

    @Test func givenConcurrentSavedRevision_whenSaving_thenStaleSaveNeverReachesRepository() async {
        // given
        let (sut, _, useCase) = makeVM()
        sut.validatedDefinition = sut.effectiveDefinition
        // when
        sut.save()
        await waitUntil { !sut.isBusy }
        // then
        #expect(sut.editorConflict != nil)
        #expect(sut.revision == 1)
        #expect(sut.definition["description"]?.stringValue == "unsaved")
        verify(useCase).save(name: .any, definition: .any, expectedRevision: .any, expectedWorkflowID: .any).called(0)
    }

    @Test func givenConflictedDraftWithBaselineRead_whenDuplicating_thenCopyCanSaveAndLateReadCannotReapplyConflict() async {
        // given
        let (sut, store, _) = makeVM()
        let controlled = ControlledWorkflowValidationUseCase()
        let copy = WorkflowVM(useCase: controlled, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        copy.draftKey = "saved:Saved"
        #expect(copy.restoreDraft())
        copy.editorConflict = "Changed"
        copy.checkEditorBaseline(WorkflowRecord(raw: current))
        await waitUntil { controlled.pendingLoad != nil }
        // when
        copy.duplicate()
        controlled.finishLoad(current)
        await Task.yield()
        // then
        #expect(copy.loadedName.isEmpty)
        #expect(copy.editorConflict == nil)
        #expect(!copy.checkingEditorBaseline)
        #expect(copy.canSave)
        #expect(copy.definition == sut.definition)
        controlled.finishAllValidations()
    }

    @Test func givenImmediateSaveValidationFailure_whenReferenceMissing_thenStructuredDiagnosticsRemainActionable() async {
        // given
        let useCase = MockWorkflowUseCase()
        let references: [JSONValue] = [.object(["target_workflow_id": .string("missing"), "node_id": .string("verify")])]
        given(useCase).backendIDs.willReturn(["codex"])
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(false), "error": .string("Missing workflow"),
                                                            "missing_references": .array(references), "missing_references_truncated": .bool(true)])
        let sut = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                             draftStore: WorkflowDraftTests().store(), visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.newWorkflow()
        sut.name = "New"
        // when
        sut.save()
        await waitUntil { !sut.isBusy }
        // then
        #expect(sut.missingReferences == WorkflowJSON.objects(.array(references)))
        #expect(sut.missingReferencesTruncated)
        #expect(sut.editorConflict == nil)
        #expect(sut.canSave)
    }

}
