import Foundation
import HfCommon
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowDiscardFlatRecordTests

@MainActor @Suite struct WorkflowDiscardFlatRecordTests {
    private var flat: [String: JSONValue] {
        WorkflowVM.starterDefinition().merging([
            "name": .string("Saved"), "workflow_id": .string("identity"),
            "revision": .number(2), "schema_version": .number(1)
        ]) { _, new in new }
    }

    @Test(arguments: [false, true])
    func givenPythonFlatGetRecord_whenConfirming_thenPreparedRevisionAndDefinitionAreRestored(legacy: Bool) async throws {
        // given
        var record = flat
        if legacy { record["workflow_id"] = nil; record["schema_version"] = nil }
        let response = WorkflowDiscardReadResponse(record)
        let (sut, store, _) = WorkflowConflictRecoveryTests().makeVM(readResponse: { try response.read() })
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        // when
        sut.discardChanges()
        await waitUntil { dialog != nil && !sut.isBusy }
        #expect(dialog?.description == "The workflow returns to revision 2, its last saved revision.")
        dialog?.actions.first { $0.title == "Discard" }?.action()
        await waitUntil { !sut.isBusy }
        // then
        #expect(response.readCount == 2)
        #expect(sut.definition == record)
        #expect(sut.savedDefinition == record)
        #expect(sut.revision == 2)
        #expect(try store.load(key: "saved:Saved") == nil)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["missing-nodes", "nodes-type", "node-type", "missing-connections", "connections-type", "edge-type",
                      "missing-orchestrator", "orchestrator-type", "schema-type", "schema-bool", "schema-version", "definition-type", "identity-type"])
    func givenMalformedFlatRecord_whenPreparingDiscard_thenDraftSurvivesWithoutConfirmation(change: String) async throws {
        // given
        var record = flat
        switch change {
        case "missing-nodes": record["nodes"] = nil
        case "nodes-type": record["nodes"] = .object([:])
        case "node-type": record["nodes"] = .array([.string("invalid")])
        case "missing-connections": record["connections"] = nil
        case "connections-type": record["connections"] = .object([:])
        case "edge-type": record["connections"] = .array([.string("invalid")])
        case "missing-orchestrator": record["orchestrator"] = nil
        case "orchestrator-type": record["orchestrator"] = .array([])
        case "schema-type": record["schema_version"] = .string("1")
        case "schema-bool": record["schema_version"] = .bool(true)
        case "schema-version": record["schema_version"] = .number(2)
        case "definition-type": record["definition"] = .string("invalid")
        default: record["workflow_id"] = .number(1)
        }
        let response = WorkflowDiscardReadResponse(record)
        let (sut, store, _) = WorkflowConflictRecoveryTests().makeVM(readResponse: { try response.read() })
        let before = try store.load(key: "saved:Saved")
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        // when
        sut.discardChanges()
        await waitUntil { !sut.isBusy }
        // then
        #expect(response.readCount == 1)
        #expect(dialog == nil)
        #expect(sut.revision == 1)
        #expect(sut.editorConflict != nil)
        #expect(try store.load(key: "saved:Saved") == before)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["identity", "revision", "definition"])
    func givenPreparedFlatRecord_whenSavedRecordChanges_thenConfirmationPreservesDraft(change: String) async throws {
        // given
        var record = flat
        let response = WorkflowDiscardReadResponse(record)
        let (sut, store, _) = WorkflowConflictRecoveryTests().makeVM(readResponse: { try response.read() })
        let before = try store.load(key: "saved:Saved")
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        sut.discardChanges()
        await waitUntil { dialog != nil && !sut.isBusy }
        // when
        if change == "identity" { record["workflow_id"] = .string("replacement") }
        if change == "revision" { record["revision"] = .number(3) }
        if change == "definition" { record["description"] = .string("changed after preparation") }
        response.set(.success(record))
        dialog?.actions.first { $0.title == "Discard" }?.action()
        await waitUntil { !sut.isBusy }
        // then
        #expect(response.readCount == 2)
        #expect(sut.revision == 1)
        #expect(sut.definition["description"] == .string("unsaved"))
        #expect(sut.editorConflict != nil)
        #expect(try store.load(key: "saved:Saved") == before)
        withExtendedLifetime(subscription) {}
    }
}
