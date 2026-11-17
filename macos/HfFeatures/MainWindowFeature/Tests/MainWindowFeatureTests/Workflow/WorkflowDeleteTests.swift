import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowDeleteTests

@MainActor @Suite struct WorkflowDeleteTests {
    private func makeVM(dirty: Bool = true) -> (WorkflowVM, WorkflowDeleteUseCase, MockWorkflowRouting) {
        let useCase = WorkflowDeleteUseCase()
        let routing = MockWorkflowRouting()
        given(routing).openWorkflowEditor(name: .any).willReturn()
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftTests().store(), visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.validationSuspended = true
        vm.draftPersistenceSuspended = true
        vm.isEditing = true
        vm.name = "Saved"
        vm.loadedName = "Saved"
        vm.revision = 1
        vm.savedDefinition = WorkflowConflictRecoveryTests().baseline
        vm.definition = vm.savedDefinition
        if dirty { vm.definition["description"] = .string("unsaved") }
        vm.draftKey = "saved:Saved"
        vm.draftPersistenceSuspended = false
        vm.persistDraft()
        return (vm, useCase, routing)
    }

    @Test(arguments: ["eligible", "never-saved", "busy", "loading", "load-failed", "not-editing", "run",
                      "baseline-check", "builder-pending", "refining", "refinement", "draft-suspended", "runtime-unavailable"])
    func givenEditorState_whenReadingDeleteEligibility_thenMenuMatchesCommandGuard(state: String) async {
        // given
        let (vm, useCase, _) = makeVM()
        switch state {
        case "runtime-unavailable": useCase.runtimeUnavailable = true
        case "never-saved": vm.loadedName = ""
        case "busy": vm.isBusy = true
        case "loading": vm.initialLoadingKind = "editor"
        case "load-failed": vm.initialLoadFailed = true
        case "not-editing": vm.isEditing = false
        case "run": vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run")])
        case "baseline-check": vm.checkingEditorBaseline = true
        case "builder-pending": vm.builderDispatchPending = true
        case "refining": vm.isRefining = true; vm.showsGenerateSheet = true
        case "refinement":
            vm.refinementContext = WorkflowRefinementContext(
                draftID: vm.draftID, loadID: vm.editorLoadID, definition: vm.definition,
                name: vm.name, loadedName: vm.loadedName, revision: vm.revision,
                baseline: vm.savedDefinition, runID: "proposal")
        case "draft-suspended": vm.draftPersistenceSuspended = true
        default: break
        }
        var dialog: AlertContent?
        var deliveryFinished = false
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { event in
            if let content = event.dialog { dialog = content } else { deliveryFinished = true }
        }
        // when
        let eligible = vm.canDeleteWorkflow
        vm.deleteWorkflow()
        if eligible { await waitUntil { dialog != nil } }
        vm.publishViewEvent(.none)
        await waitUntil { deliveryFinished }
        // then
        #expect(eligible == (state == "eligible"))
        #expect((dialog != nil) == eligible)
        #expect(useCase.commandCount == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: [false, true])
    func givenSavedEditor_whenDeletingThenCancelling_thenDefaultCancelPreservesDraft(dirty: Bool) async throws {
        // given
        let (vm, useCase, _) = makeVM(dirty: dirty)
        var dialog: AlertContent?
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        let before = try vm.draftStore.load(key: "saved:Saved")
        // when
        vm.deleteWorkflow()
        await waitUntil { dialog != nil }
        let content = try #require(dialog)
        let cancel = try #require(content.actions.first { $0.title == "Cancel" })
        #expect(cancel.isDefault)
        #expect(content.title == "Delete workflow ‘Saved’?")
        #expect(content.description?.contains("Unsaved changes will be lost.") == dirty)
        cancel.action()
        let confirm = try #require(content.actions.first { $0.title == "Delete" })
        confirm.action()
        // then
        #expect(useCase.deleteCount == 0)
        #expect(try vm.draftStore.load(key: "saved:Saved") == before)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenAbandonedConfirmation_whenReopened_thenOnlyNewestRequestCanDeleteOnce() async throws {
        // given
        let (vm, useCase, routing) = makeVM()
        var dialogs: [AlertContent] = []
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { if let dialog = $0.dialog { dialogs.append(dialog) } }
        vm.deleteWorkflow()
        await waitUntil { dialogs.count == 1 }
        let old = try #require(dialogs.first)
        // when
        vm.deleteWorkflow()
        await waitUntil { dialogs.count == 2 }
        let current = try #require(dialogs.last)
        let oldCancel = try #require(old.actions.first { $0.title == "Cancel" })
        let oldConfirm = try #require(old.actions.first { $0.title == "Delete" })
        oldCancel.action()
        oldConfirm.action()
        #expect(useCase.deleteCount == 0)
        let confirm = try #require(current.actions.first { $0.title == "Delete" })
        confirm.action()
        confirm.action()
        await waitUntil { useCase.pending != nil }
        useCase.finish(.success(["deleted": .string("Saved")]))
        await waitUntil { !vm.isBusy }
        // then
        #expect(useCase.deleteCount == 1)
        #expect(useCase.deletedNames == ["Saved"])
        verify(routing).openWorkflowEditor(name: .value(nil)).called(1)
        #expect(vm.deleteFailureText == nil)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["editor", "draft", "generation", "name", "definition", "baseline", "revision", "runtime", "completion", "disappear", "run"])
    func givenPreparedConfirmation_whenContextChanges_thenDeleteIsNotSent(change: String) async throws {
        // given
        let (vm, useCase, _) = makeVM()
        var dialog: AlertContent?
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        vm.deleteWorkflow()
        await waitUntil { dialog != nil }
        let confirm = try #require(dialog?.actions.first { $0.title == "Delete" })
        let id = vm.draftID
        defer { WorkflowDraftCompletion.completed[id] = nil }
        // when
        changeContext(change, vm: vm, useCase: useCase)
        vm.errorText = "Later editor error"
        confirm.action()
        await Task.yield()
        // then
        #expect(useCase.deleteCount == 0)
        #expect(vm.errorText == "Later editor error")
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["editor", "generation", "runtime", "runtime-unavailable", "completion", "disappear", "run"])
    func givenQueuedDelete_whenContextChangesBeforeDispatch_thenNoCommandOrLaterEditorMutation(change: String) async throws {
        // given
        let (vm, useCase, routing) = makeVM()
        var dialog: AlertContent?
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        vm.deleteWorkflow()
        await waitUntil { dialog != nil }
        let confirm = try #require(dialog?.actions.first { $0.title == "Delete" })
        let id = vm.draftID
        defer { WorkflowDraftCompletion.completed[id] = nil }
        // when
        confirm.action()
        changeContext(change, vm: vm, useCase: useCase)
        vm.errorText = "Later editor error"
        let definition = vm.definition
        let before = try vm.draftStore.load(key: "saved:Saved")
        await waitUntil { !vm.isBusy }
        // then
        #expect(useCase.commandCount == 0)
        #expect(vm.errorText == "Later editor error")
        #expect(vm.deleteFailureText == nil)
        #expect(vm.definition == definition)
        #expect(try vm.draftStore.load(key: "saved:Saved") == before)
        verify(routing).openWorkflowEditor(name: .any).called(0)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["editor", "generation", "runtime", "completion", "disappear", "run"], ["success", "error", "malformed"])
    func givenInFlightDelete_whenContextChanges_thenLateResultCannotAffectLaterEditor(change: String, result: String) async throws {
        // given
        let (vm, useCase, routing) = makeVM()
        var dialog: AlertContent?
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        vm.deleteWorkflow()
        await waitUntil { dialog != nil }
        let confirm = try #require(dialog?.actions.first { $0.title == "Delete" })
        confirm.action()
        await waitUntil { useCase.pending != nil }
        let id = vm.draftID
        defer { WorkflowDraftCompletion.completed[id] = nil }
        // when
        changeContext(change, vm: vm, useCase: useCase)
        vm.errorText = "Later editor error"
        let definition = vm.definition
        let before = try vm.draftStore.load(key: "saved:Saved")
        if result == "error" {
            useCase.finish(.failure(WorkflowUIError.missingRun))
        } else {
            useCase.finish(.success(result == "success" ? ["deleted": .string("Saved")] : [:]))
        }
        await waitUntil { !vm.isBusy }
        // then
        verify(routing).openWorkflowEditor(name: .any).called(0)
        #expect(vm.errorText == "Later editor error")
        #expect(vm.deleteFailureText == nil)
        #expect(vm.definition == definition)
        #expect(try vm.draftStore.load(key: "saved:Saved") == before)
        #expect(useCase.commandCount == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: ["missing", "malformed", "wrong", "error"])
    func givenCurrentEditor_whenDeleteIsUnconfirmed_thenFailurePreservesDraftWithoutRetry(result: String) async throws {
        // given
        let (vm, useCase, routing) = makeVM()
        var dialog: AlertContent?
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { dialog = $0.dialog }
        let before = try vm.draftStore.load(key: "saved:Saved")
        vm.deleteWorkflow()
        await waitUntil { dialog != nil }
        let confirm = try #require(dialog?.actions.first { $0.title == "Delete" })
        confirm.action()
        await waitUntil { useCase.pending != nil }
        // when
        switch result {
        case "error": useCase.finish(.failure(WorkflowUIError.missingRun))
        case "malformed": useCase.finish(.success(["deleted": .bool(true)]))
        case "wrong": useCase.finish(.success(["deleted": .string("Other")]))
        default: useCase.finish(.success([:]))
        }
        await waitUntil { !vm.isBusy }
        // then
        verify(routing).openWorkflowEditor(name: .any).called(0)
        #expect(vm.deleteFailureText != nil)
        if result != "error" { #expect(vm.deleteFailureText?.contains("may already be deleted") == true) }
        #expect(vm.errorText == nil)
        #expect(try vm.draftStore.load(key: "saved:Saved") == before)
        #expect(useCase.commandCount == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenNeverSavedEditor_whenDeleting_thenNoDialogOrCommand() async {
        // given
        let (vm, useCase, _) = makeVM()
        vm.loadedName = ""
        var dialog: AlertContent?
        var deliveryFinished = false
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { event in
            if let content = event.dialog { dialog = content } else { deliveryFinished = true }
        }
        // when
        vm.deleteWorkflow()
        vm.publishViewEvent(.none)
        await waitUntil { deliveryFinished }
        // then
        #expect(dialog == nil)
        #expect(useCase.commandCount == 0)
        withExtendedLifetime(subscription) {}
    }

    private func changeContext(_ change: String, vm: WorkflowVM, useCase: WorkflowDeleteUseCase) {
        switch change {
        case "editor": vm.editorLoadID = UUID()
        case "draft": vm.draftID = UUID()
        case "generation": vm.generationID = UUID()
        case "name": vm.name = "Renamed"
        case "definition": vm.definition["description"] = .string("new edit")
        case "baseline": vm.savedDefinition["description"] = .string("new baseline")
        case "revision": vm.revision += 1
        case "runtime-unavailable": useCase.runtimeUnavailable = true
        case "runtime": useCase.runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/other-ctl", environment: [:]))
        case "completion": WorkflowDraftCompletion.completed[vm.draftID] = .init(name: "Saved", revision: 2, submitted: vm.definition, saved: vm.definition)
        case "disappear": vm.didDisappear()
        case "run": vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("later-run"), "status": .string("running")])
        default: break
        }
    }
}

// MARK: - WorkflowDeleteUseCase

@MainActor private final class WorkflowDeleteUseCase: WorkflowUseCase, @unchecked Sendable {
    var runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
    var runtimeUnavailable = false
    var pending: CheckedContinuation<[String: JSONValue], any Error>?
    var deletedNames: [String] = []
    var commandCount = 0
    var deleteCount: Int { deletedNames.count }
    var backendIDs: [String] { ["codex"] }

    func activityRuntime() throws -> QualificationRuntimeToken {
        guard !runtimeUnavailable else { throw WorkflowUIError.missingRun }
        return runtime
    }

    func command(_ command: String, options _: [String], positionals: [String], runtime _: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        commandCount += 1
        guard command == "delete" else { return [:] }
        deletedNames.append(contentsOf: positionals)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func finish(_ result: Result<[String: JSONValue], any Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { ["valid": .bool(true)] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int, expectedWorkflowID _: String?) async throws -> [String: JSONValue] { [:] }
    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
