import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowUndoTests

@MainActor
@Suite struct WorkflowUndoTests {
    @Test func givenNewWorkflow_whenDiscardingEditsAndReopening_thenStarterHasNoDraft() throws {
        // given
        let helper = WorkflowDraftTests()
        let store = helper.store()
        let sut = helper.vm(store: store)
        sut.newWorkflow()
        #expect(!sut.canDiscard)
        sut.name = "Temporary"
        sut.addNode("review")
        // when
        sut.discardChanges()
        let reopened = helper.vm(store: store)
        reopened.newWorkflow()
        // then
        #expect(sut.name.isEmpty)
        #expect(sut.definition == WorkflowVM.starterDefinition())
        #expect(!sut.canUndo)
        #expect(!sut.canDiscard)
        #expect(try store.load(key: "new") == nil)
        #expect(reopened.name.isEmpty)
        #expect(reopened.definition == WorkflowVM.starterDefinition())
    }

    @Test func givenSavedDraft_whenDiscarding_thenOriginalNameRevisionAndBaselineSurviveReopen() throws {
        // given
        let helper = WorkflowDraftTests()
        let store = helper.store()
        let baseline = WorkflowVM.starterDefinition()
        var changed = baseline
        changed["description"] = .string("Changed")
        try store.save(["draft_id": .string(UUID().uuidString), "name": .string("Renamed"), "loaded_name": .string("Saved"), "revision": .number(7),
                        "definition": .object(changed), "saved_definition": .object(baseline)], key: "saved:Saved")
        let sut = helper.vm(store: store)
        sut.draftKey = "saved:Saved"
        #expect(sut.restoreDraft())
        // when
        sut.discardChanges()
        sut.persistDraft()
        // then
        #expect(sut.name == "Saved")
        #expect(sut.loadedName == "Saved")
        #expect(sut.revision == 7)
        #expect(sut.definition == baseline)
        #expect(!sut.canSave)
        #expect(try store.load(key: "saved:Saved") == nil)
        #expect(!sut.restoreDraft())
    }

    @Test func givenMultiNodeDrag_whenMovingManyTimes_thenOneUndoRestoresAllPositions() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        let baseline = sut.definition
        // when
        sut.beginNodeDrag()
        sut.moveNodes(["start": CGPoint(x: 100, y: 120), "planning": CGPoint(x: 300, y: 120)])
        sut.moveNodes(["start": CGPoint(x: 200, y: 240), "planning": CGPoint(x: 400, y: 240)])
        sut.endNodeDrag()
        sut.undoWorkflowEdit()
        // then
        #expect(sut.definition == baseline)
        #expect(!sut.canUndo)
    }

    @Test func givenSelectedNodeWithConnections_whenDeletingAndUndoing_thenGraphRestoresAtomically() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        let baseline = sut.definition
        sut.selectNode("planning")
        // when
        sut.deleteSelected()
        #expect(sut.definition != baseline)
        sut.undoWorkflowEdit()
        // then
        #expect(sut.definition == baseline)
        #expect(!sut.canUndo)
    }

    @Test func givenInspectorAndNameEdits_whenUndoing_thenLatestEditAndPersistentDraftFollowHistory() throws {
        // given
        let helper = WorkflowDraftTests()
        let store = helper.store()
        let sut = helper.vm(store: store)
        sut.newWorkflow()
        sut.name = "Workflow"
        let baseline = sut.definition
        sut.updateNode("planning", key: "instructions", value: .string("Edited"))
        // when
        sut.undoWorkflowEdit()
        // then
        #expect(sut.name == "Workflow")
        #expect(sut.definition == baseline)
        #expect(try store.load(key: "new")?["definition"]?.objectValue == baseline)
        sut.undoWorkflowEdit()
        #expect(sut.name.isEmpty)
        #expect(try store.load(key: "new") == nil)
    }

    @Test func givenEditHistory_whenNavigatingToNewWorkflow_thenHistoryDoesNotCrossEditors() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        sut.addNode("review")
        #expect(sut.canUndo)
        // when
        sut.newWorkflow()
        // then
        #expect(!sut.canUndo)
        #expect(sut.nodes.contains { $0.type == "agent" && $0.raw["role"]?.stringValue == "review" })
    }

    @Test func givenNewlySavedBaseline_whenUndoingThenDiscarding_thenSavedMetadataRemainsCurrent() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        sut.name = "Saved"
        sut.updateNode("planning", key: "instructions", value: .string("Saved edit"))
        let saved = sut.definition
        sut.loadedName = "Saved"
        sut.revision = 9
        sut.savedDefinition = saved
        // when
        sut.undoWorkflowEdit()
        // then
        #expect(sut.definition != saved)
        #expect(sut.loadedName == "Saved")
        #expect(sut.revision == 9)
        #expect(sut.savedDefinition == saved)
        #expect(sut.canDiscard)
        sut.discardChanges()
        #expect(sut.definition == saved)
        #expect(!sut.canSave)
    }

    @Test func givenBusyEditor_whenDiscardingOrUndoing_thenAgentWorkIsPreserved() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        sut.name = "In progress"
        let edited = sut.definition
        sut.builderDispatchPending = true
        // when
        sut.undoWorkflowEdit()
        sut.discardChanges()
        // then
        #expect(sut.name == "In progress")
        #expect(sut.definition == edited)
        #expect(!sut.canDiscard)
    }

    @Test func givenUnsavedNewWorkflow_whenDuplicateIsRejected_thenEditHistoryRemainsUndoable() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        sut.name = "Unsaved"
        // when
        sut.duplicate()
        // then
        #expect(sut.canUndo)
        sut.undoWorkflowEdit()
        #expect(sut.name.isEmpty)
        #expect(!sut.canUndo)
    }

    @Test func givenSeveralGraphEdits_whenUndoingRepeatedly_thenEachPriorStateRestoresUntilHistoryIsExhausted() {
        // given
        let helper = WorkflowDraftTests()
        let sut = helper.vm(store: helper.store())
        sut.newWorkflow()
        var snapshots = [sut.definition]
        sut.addNode("review")
        snapshots.append(sut.definition)
        sut.moveNode("planning", to: CGPoint(x: 300, y: 340))
        snapshots.append(sut.definition)
        sut.updateNode("planning", key: "instructions", value: .string("New instructions"))
        snapshots.append(sut.definition)
        sut.selectNode("planning")
        sut.deleteSelected()
        // when / then
        for expected in snapshots.reversed() {
            #expect(sut.canUndo)
            sut.undoWorkflowEdit()
            #expect(sut.definition == expected)
        }
        #expect(!sut.canUndo)
        sut.undoWorkflowEdit()
        #expect(sut.definition == WorkflowVM.starterDefinition())
    }

}
