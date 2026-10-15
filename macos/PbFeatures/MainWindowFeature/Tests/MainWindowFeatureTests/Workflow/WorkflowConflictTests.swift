import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

// MARK: - WorkflowConflictTests

@MainActor
@Suite struct WorkflowConflictTests {
    func harness(current: [String: JSONValue]) -> (WorkflowVM, WorkflowDraftStore) {
        let store = WorkflowDraftTests().store()
        let useCase = MockWorkflowUseCase()
        given(useCase).backendIDs.willReturn(["codex"])
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(false)])
        given(useCase).command(.value("get"), options: .any, positionals: .any).willReturn(current)
        return (WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut, draftStore: store), store)
    }

    @Test func givenStaleDraft_whenRestored_thenCurrentReadDetectsConflictWithoutLosingEdits() async throws {
        // given
        let baseline: [String: JSONValue] = ["workflow_id": .string("old"), "description": .string("baseline")]
        let current: [String: JSONValue] = ["name": .string("Saved"), "revision": .number(2), "definition": .object(baseline)]
        let (sut, store) = harness(current: current)
        let edits: [String: JSONValue] = ["description": .string("unsaved")]
        try store.save(["draft_id": .string(UUID().uuidString), "name": .string("Saved"), "loaded_name": .string("Saved"),
                        "revision": .number(1), "saved_definition": .object(baseline), "definition": .object(edits)], key: "saved:Saved")
        // when
        sut.selectWorkflow(WorkflowRecord(raw: current))
        await waitUntil { !sut.checkingEditorBaseline }
        // then
        #expect(sut.definition == edits)
        #expect(sut.revision == 1)
        #expect(sut.editorConflict != nil)
        #expect(!sut.canSave)
        #expect(try store.load(key: "saved:Saved")?["definition"] == .object(edits))
    }

    @Test func givenRecreatedWorkflowAtSameRevision_whenComparingBaseline_thenIdentityMismatchIsConflict() {
        // given
        let (sut, _) = harness(current: [:])
        sut.loadedName = "Saved"
        sut.revision = 1
        sut.savedDefinition = ["workflow_id": .string("original")]
        // when / then
        #expect(!sut.baselineMatches(WorkflowRecord(raw: ["name": .string("Saved"), "revision": .number(1),
                                                                      "definition": .object(["workflow_id": .string("replacement")])])))
    }

    @Test func givenTwoMissingReferences_whenReplacingOneThenBatchCancelled_thenOtherAndNestedRemainUnchanged() async {
        // given
        let (sut, _) = harness(current: [:])
        sut.newWorkflow()
        let node: (String, String) -> JSONValue = { id, target in
            .object(["id": .string(id), "type": .string("workflow"), "workflow_ref": .object(["workflow_id": .string(target)])])
        }
        sut.definition["nodes"] = .array([node("a", "missing"), node("b", "missing"), node("unrelated", "other")])
        sut.definition["nested"] = .object(["nodes": .array([node("nested", "missing")])])
        sut.workflows = [WorkflowRecord(raw: ["name": .string("Replacement"), "workflow_id": .string("new")])]
        // when
        sut.updateNode("a", key: "workflow_ref", value: .object(["workflow_id": .string("new")]))
        let before = sut.definition
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        sut.replaceMissingReferences("missing", with: "new")
        await waitUntil { dialog != nil }
        // then: presenting and cancelling the review makes no mutation.
        #expect(sut.nodes.first { $0.id == "b" }?.workflowID == "missing")
        #expect(dialog?.description?.contains("b") == true)
        #expect(sut.definition == before)
        // when
        dialog?.actions.first?.action()
        // then
        #expect(sut.nodes.first { $0.id == "b" }?.workflowID == "new")
        #expect(sut.nodes.first { $0.id == "unrelated" }?.workflowID == "other")
        #expect(sut.definition["nested"] == before["nested"])
        withExtendedLifetime(subscription) {}
    }
}
