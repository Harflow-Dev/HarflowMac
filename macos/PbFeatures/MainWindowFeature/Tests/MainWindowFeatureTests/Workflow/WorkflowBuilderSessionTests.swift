import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import PbTestUtilities
import Testing

// MARK: - WorkflowBuilderSessionTests

@MainActor
@Suite struct WorkflowBuilderSessionTests {
    func vm(store: WorkflowDraftStore, useCase: BuilderSessionUseCase) -> WorkflowVM {
        WorkflowVM(useCase: useCase, routing: WorkflowTests().makeVM().sut.routing,
                   parallel: ParallelVMTests().makeSUT().sut, draftStore: store)
    }

    @Test(arguments: ["running", "completed"])
    func givenUnappliedBuilderSession_whenRecreatingEditor_thenSameAgentAndOriginalCanvasReconnect(status: String) async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: status)
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow()
        first.name = "Saved workflow"
        first.loadedName = first.name
        first.draftKey = "saved:" + first.name
        first.revision = 7
        first.savedDefinition = first.definition
        let original = first.definition
        first.prepareGeneration(refining: true)
        first.prompt = "Refine this workflow"
        // when
        first.generate()
        await waitUntil { first.selectedRun?.status == status && !first.isBusy }
        first.didDisappear()
        let reopened = vm(store: store, useCase: useCase)
        reopened.selectWorkflow(WorkflowRecord(raw: ["name": .string("Saved workflow")]))
        // then
        #expect(reopened.selectedRun?.id == "builder-run")
        #expect(reopened.selectedRun?.status == status)
        #expect(reopened.definition == original)
        #expect(reopened.savedDefinition == original)
        #expect(reopened.revision == 7)
        #expect(reopened.refinementContext?.loadID == reopened.editorLoadID)
        #expect(useCase.buildCount == 1)
        if status == "completed" {
            reopened.applyAgentProposal()
            let applied = vm(store: store, useCase: useCase)
            applied.selectWorkflow(WorkflowRecord(raw: ["name": .string("Saved workflow")]))
            #expect(applied.selectedRun == nil)
            #expect(applied.definition["description"]?.stringValue == "Agent proposal")
            #expect(try store.load(key: "saved:Saved workflow")?["builder_session"] == nil)
        }
    }

    @Test(arguments: [false, true])
    func givenBuildDispatchPending_whenNavigatingAndReturningBeforeResponse_thenLateSessionReconnectsWithoutAnotherBuild(savedWorkflow: Bool) async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running")
        useCase.delayBuild = true
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow()
        first.name = "Unfinished workflow"
        if savedWorkflow {
            first.loadedName = first.name
            first.revision = 7
            first.savedDefinition = first.definition
            first.draftKey = "saved:" + first.name
        }
        let key = savedWorkflow ? "saved:Unfinished workflow" : "new"
        first.prepareGeneration(refining: true)
        first.persistDraft()
        first.generate()
        await waitUntil { useCase.pendingBuild != nil }
        first.didDisappear()
        let reopened = vm(store: store, useCase: useCase)
        if savedWorkflow { reopened.selectWorkflow(WorkflowRecord(raw: ["name": .string("Unfinished workflow")])) } else { reopened.newWorkflow() }
        #expect(reopened.draftID == first.draftID)
        #expect(reopened.isBusy)
        #expect(!reopened.canSave)
        reopened.generate()
        #expect(useCase.buildCount == 1)
        // when
        useCase.finishBuild()
        await waitUntil { !first.isBusy }
        reopened.persistDraft()
        await reopened.refresh()
        // then
        #expect(reopened.selectedRun?.id == "builder-run")
        #expect(reopened.selectedRun?.status == "running")
        #expect(useCase.buildCount == 1)
        #expect(try store.load(key: key)?["builder_session"]?["run"]?["workflow_run_id"]?.stringValue == "builder-run")
        reopened.returnToCanvas()
        let returned = vm(store: store, useCase: useCase)
        if savedWorkflow { returned.selectWorkflow(WorkflowRecord(raw: ["name": .string("Unfinished workflow")])) } else { returned.newWorkflow() }
        #expect(returned.selectedRun == nil)
    }

    @Test(arguments: ["previous-process", ""])
    func givenPendingDispatchFromPreviousAppLifetime_whenRestoring_thenDraftSurvivesAndUserCanInspectHistory(owner: String) throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let original = WorkflowVM.starterDefinition()
        try store.save(["draft_id": .string(UUID().uuidString), "name": .string("Interrupted draft"),
                        "definition": .object(original), "saved_definition": .object([:]), "revision": .number(0),
                        "builder_dispatch_pending": .bool(true), "builder_dispatch_owner": .string(owner)], key: "new")
        let useCase = BuilderSessionUseCase(status: "running")
        // when
        let restored = vm(store: store, useCase: useCase)
        restored.newWorkflow()
        // then
        #expect(!restored.isBusy)
        #expect(restored.selectedRun == nil)
        #expect(restored.definition == original)
        #expect(restored.name == "Interrupted draft")
        #expect(restored.errorText?.contains("Check workflow history") == true)
        #expect(try store.load(key: "new")?["builder_dispatch_pending"] == nil)
        #expect(useCase.buildCount == 0)
    }

    @Test(arguments: ["failure", "missing-id"])
    func givenFailedOrMalformedDispatch_whenReopening_thenPendingReservationIsClearedAndRetryIsPossible(response: String) async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running")
        useCase.buildResponse = response
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow()
        first.name = "Retry workflow"
        // when
        first.generate()
        await waitUntil { useCase.buildCount == 1 && !first.isBusy }
        let reopened = vm(store: store, useCase: useCase)
        reopened.newWorkflow()
        // then
        #expect(!reopened.builderDispatchPending)
        #expect(reopened.selectedRun == nil)
        #expect(try store.load(key: "new")?["builder_dispatch_pending"] == nil)
        reopened.generate()
        await waitUntil { useCase.buildCount == 2 && !reopened.isBusy }
    }

}

// MARK: - BuilderSessionUseCase

@MainActor
final class BuilderSessionUseCase: WorkflowUseCase, @unchecked Sendable {
    var status: String
    var delayBuild = false
    var buildCount = 0
    var buildResponse = "success"
    var pendingBuild: CheckedContinuation<[String: JSONValue], Never>?
    init(status: String) { self.status = status }
    var backendIDs: [String] { ["codex"] }
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
    func refreshTasks() async {}
    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { ["valid": .bool(true)] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] { [:] }
    func command(_ command: String, options _: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        if command == "build" {
            buildCount += 1
            if buildResponse == "failure" { throw CocoaError(.fileReadUnknown) }
            if buildResponse == "missing-id" { return [:] }
            if delayBuild { return await withCheckedContinuation { pendingBuild = $0 } }
            return ["workflow_run_id": .string("builder-run")]
        }
        if command == "status" {
            var proposal = WorkflowVM.starterDefinition()
            proposal["description"] = .string("Agent proposal")
            return ["run": .object(["workflow_run_id": .string("builder-run"), "kind": .string("builder"), "status": .string(status),
                                    "workflow_name": .string("Saved workflow"), "editing_definition": .object(WorkflowVM.starterDefinition()),
                                    "generated_definition": .object(proposal)])]
        }
        return [:]
    }

    func finishBuild() {
        pendingBuild?.resume(returning: ["workflow_run_id": .string("builder-run")])
        pendingBuild = nil
    }
}
