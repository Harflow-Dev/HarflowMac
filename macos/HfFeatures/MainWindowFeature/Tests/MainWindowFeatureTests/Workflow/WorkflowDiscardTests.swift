import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowDiscardTests

@MainActor @Suite struct WorkflowDiscardTests {
    @Test func givenFreshSavedRevision_whenCancelThenOldConfirmRuns_thenDraftAndHistorySurvive() async throws {
        // given
        let (sut, store, _) = WorkflowConflictRecoveryTests().makeVM()
        let before = try store.load(key: "saved:Saved")
        let history = sut.editHistory
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        // when
        sut.discardChanges()
        await waitUntil { dialog != nil && !sut.isBusy }
        let content = try #require(dialog)
        #expect(content.title == "Discard unsaved changes?")
        #expect(content.description == "The workflow returns to revision 2, its last saved revision.")
        let cancel = try #require(content.actions.first { $0.title == "Cancel" })
        #expect(cancel.isDefault)
        cancel.action()
        content.actions.first { $0.title == "Discard" }?.action()
        // then
        #expect(sut.revision == 1)
        #expect(sut.editHistory == history)
        #expect(try store.load(key: "saved:Saved") == before)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenPreparedRevision_whenConfirmedTwice_thenFreshBaselineIsAppliedOnlyOnce() async throws {
        // given
        let (sut, store, useCase) = WorkflowConflictRecoveryTests().makeVM()
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        sut.discardChanges()
        await waitUntil { dialog != nil && !sut.isBusy }
        let confirm = try #require(dialog?.actions.first { $0.title == "Discard" })
        // when
        confirm.action()
        confirm.action()
        await waitUntil { !sut.isBusy }
        // then
        #expect(sut.revision == 2)
        #expect(sut.definition == WorkflowConflictRecoveryTests().baseline)
        #expect(try store.load(key: "saved:Saved") == nil)
        verify(useCase).command(.value("get"), options: .any, positionals: .any, runtime: .any).called(2)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["editor", "generation", "completion", "changed", "malformed", "failed"])
    func givenPreparedDiscard_whenAuthorityChanges_thenDraftIsPreserved(change: String) async throws {
        // given
        let response = WorkflowDiscardReadResponse(WorkflowConflictRecoveryTests().current)
        let (sut, store, useCase) = WorkflowConflictRecoveryTests().makeVM(readResponse: { try response.read() })
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        sut.discardChanges()
        await waitUntil { dialog != nil && !sut.isBusy }
        let id = sut.draftID
        defer { WorkflowDraftCompletion.completed[id] = nil }
        let before = try store.load(key: "saved:Saved")
        // when
        switch change {
        case "editor": sut.editorLoadID = UUID()
        case "generation": sut.generationID = UUID()
        case "completion":
            WorkflowDraftCompletion.completed[id] = .init(name: "Saved", revision: 3, submitted: sut.definition, saved: sut.definition)
        case "failed":
            response.set(.failure(WorkflowUIError.missingRun))
        default:
            var current = WorkflowConflictRecoveryTests().current
            if change == "changed" { current["revision"] = .number(3) } else { current["definition"] = nil }
            response.set(.success(current))
        }
        sut.errorText = "Current editor error"
        sut.editorConflict = "Current editor conflict"
        dialog?.actions.first { $0.title == "Discard" }?.action()
        await waitUntil { !sut.isBusy }
        // then
        if ["editor", "generation", "completion"].contains(change) {
            #expect(sut.errorText == "Current editor error")
            #expect(sut.editorConflict == "Current editor conflict")
        }
        let expectedReads = ["editor", "generation", "completion"].contains(change) ? 1 : 2
        #expect(response.readCount == expectedReads)
        verify(useCase).command(.value("get"), options: .any, positionals: .any, runtime: .any).called(.exactly(expectedReads))
        #expect(sut.revision == 1)
        #expect(sut.definition["description"] == .string("unsaved"))
        #expect(try store.load(key: "saved:Saved") == before)
        if change == "completion" { #expect(WorkflowDraftCompletion.completed[id]?.revision == 3) }
        withExtendedLifetime(subscription) {}
    }

    @Test func givenMalformedInitialRead_whenDiscarding_thenNoConfirmationOrDeletionOccurs() async throws {
        // given
        let response = WorkflowDiscardReadResponse(["name": .string("Saved"), "revision": .number(2), "nodes": .array([])])
        let (sut, store, useCase) = WorkflowConflictRecoveryTests().makeVM(readResponse: { try response.read() })
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        // when
        sut.discardChanges()
        await waitUntil { !sut.isBusy }
        // then
        #expect(response.readCount == 1)
        verify(useCase).command(.value("get"), options: .any, positionals: .any, runtime: .any).called(1)
        #expect(dialog == nil)
        #expect(sut.editorConflict != nil)
        #expect(try store.load(key: "saved:Saved") != nil)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: [false, true], ["completion", "editor"])
    func givenSuspendedDiscardRead_whenAuthorityChanges_thenDraftAndCurrentEditorSurvive(confirming: Bool, change: String) async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let store = WorkflowDraftTests().store()
        let sut = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                             draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.draftPersistenceSuspended = true
        sut.name = "Saved"
        sut.loadedName = "Saved"
        sut.revision = 1
        sut.savedDefinition = WorkflowConflictRecoveryTests().baseline
        sut.definition = sut.savedDefinition.merging(["description": .string("unsaved")]) { _, new in new }
        sut.isEditing = true
        sut.draftKey = "saved:Saved"
        sut.draftPersistenceSuspended = false
        sut.persistDraft()
        sut.draftWriteTask?.cancel()
        let id = sut.draftID
        defer { WorkflowDraftCompletion.completed[id] = nil; useCase.finishAllValidations() }
        let before = try store.load(key: "saved:Saved")
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        sut.discardChanges()
        await waitUntil { useCase.pendingLoad != nil }
        if confirming {
            useCase.finishLoad(WorkflowConflictRecoveryTests().current)
            await waitUntil { dialog != nil && !sut.isBusy }
            dialog?.actions.first { $0.title == "Discard" }?.action()
            await waitUntil { useCase.pendingLoad != nil }
        }
        // when
        if change == "completion" {
            WorkflowDraftCompletion.completed[id] = .init(name: "Saved", revision: 3, submitted: sut.definition, saved: sut.definition)
        } else {
            sut.editorLoadID = UUID()
        }
        sut.errorText = "New editor error"
        sut.editorConflict = "New editor conflict"
        let definition = sut.definition
        useCase.finishLoad(WorkflowConflictRecoveryTests().current)
        await waitUntil { !sut.isBusy }
        // then
        #expect(sut.revision == 1)
        #expect(try store.load(key: "saved:Saved") == before)
        #expect(sut.errorText == "New editor error")
        #expect(sut.editorConflict == "New editor conflict")
        #expect(sut.definition == definition)
        #expect(sut.draftID == id)
        if change == "completion" { #expect(WorkflowDraftCompletion.completed[id]?.revision == 3) }
        withExtendedLifetime(subscription) {}
    }

    @Test func givenAbandonedConfirmation_whenPreparingAgain_thenOldCallbacksCannotConsumeNewRequest() async throws {
        // given
        let (sut, store, _) = WorkflowConflictRecoveryTests().makeVM()
        let before = try store.load(key: "saved:Saved")
        var dialogs: [AlertContent] = []
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { if let dialog = $0.dialog { dialogs.append(dialog) } }
        sut.discardChanges()
        await waitUntil { dialogs.count == 1 && !sut.isBusy }
        let old = try #require(dialogs.first)
        // when
        sut.discardChanges()
        await waitUntil { dialogs.count == 2 && !sut.isBusy }
        let requestID = try #require(sut.discardRequestID)
        old.actions.first { $0.title == "Cancel" }?.action()
        old.actions.first { $0.title == "Discard" }?.action()
        // then
        #expect(sut.discardRequestID == requestID)
        #expect(sut.errorText == nil)
        #expect(sut.editorConflict == nil)
        #expect(try store.load(key: "saved:Saved") == before)
        dialogs.last?.actions.first { $0.title == "Cancel" }?.action()
        #expect(sut.discardRequestID == nil)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenConfirmation_whenEditorDisappears_thenCallbacksCannotChangeCurrentErrorsOrDraft() async throws {
        // given
        let (sut, store, _) = WorkflowConflictRecoveryTests().makeVM()
        var dialog: AlertContent?
        let subscription = sut.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        sut.discardChanges()
        await waitUntil { dialog != nil && !sut.isBusy }
        // when
        sut.didDisappear()
        let before = try store.load(key: "saved:Saved")
        let definition = sut.definition
        let draftID = sut.draftID
        sut.errorText = "New editor error"
        sut.editorConflict = "New editor conflict"
        dialog?.actions.first { $0.title == "Discard" }?.action()
        // then
        #expect(sut.discardRequestID == nil)
        #expect(sut.errorText == "New editor error")
        #expect(sut.editorConflict == "New editor conflict")
        #expect(sut.definition == definition)
        #expect(sut.draftID == draftID)
        #expect(try store.load(key: "saved:Saved") == before)
        withExtendedLifetime(subscription) {}
    }

}

// MARK: - WorkflowDiscardReadResponse

private final class WorkflowDiscardReadResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String: JSONValue], any Error>
    private var count = 0

    init(_ response: [String: JSONValue]) { self.result = .success(response) }
    var readCount: Int { lock.withLock { count } }
    func set(_ result: Result<[String: JSONValue], any Error>) { lock.withLock { self.result = result } }
    func read() throws -> [String: JSONValue] {
        try lock.withLock {
            count += 1
            return try result.get()
        }
    }
}
