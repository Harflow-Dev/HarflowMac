import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowBuilderSessionTests

@MainActor
@Suite struct WorkflowBuilderSessionTests {
    func vm(store: any WorkflowDraftStoring, useCase: BuilderSessionUseCase) -> WorkflowVM {
        WorkflowVM(useCase: useCase, routing: WorkflowTests().makeVM().sut.routing,
                   parallel: ParallelVMTests().makeSUT().sut, draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
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
        #expect(restored.isBusy)
        #expect(restored.builderDispatchPending)
        #expect(restored.selectedRun == nil)
        #expect(restored.definition == original)
        #expect(restored.name == "Interrupted draft")
        #expect(restored.errorText?.contains("Check workflow history") == true)
        #expect(try store.load(key: "new")?["builder_dispatch_pending"] == .bool(true))
        #expect(useCase.buildCount == 0)
    }

    @Test(arguments: ["failure", "missing-id"])
    func givenFailedOrMalformedDispatch_whenReopening_thenPendingReservationSurvivesAndRetryIsBlocked(response: String) async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running")
        useCase.buildResponse = response
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow()
        first.name = "Retry workflow"
        // when
        first.generate()
        await waitUntil { useCase.buildCount == 1 && first.errorText != nil }
        let reopened = vm(store: store, useCase: useCase)
        reopened.newWorkflow()
        // then
        #expect(reopened.builderDispatchPending)
        #expect(reopened.isBusy)
        #expect(reopened.selectedRun == nil)
        #expect(try store.load(key: "new")?["builder_dispatch_pending"] == .bool(true))
        reopened.generate()
        #expect(useCase.buildCount == 1)
    }

    @Test(arguments: ["executable", "state-root", "product-version"])
    func givenPersistedBuilderSession_whenRuntimeBindingChanges_thenRunIsNotAdoptedAndReservationSurvives(change: String) async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running")
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow(); first.name = "Bound workflow"; first.prepareGeneration(refining: true); first.generate()
        await waitUntil { first.selectedRun?.id == "builder-run" && !first.isBusy }
        useCase.runtimeToken = runtime(change: change)
        // when
        let reopened = vm(store: store, useCase: useCase)
        reopened.newWorkflow()
        // then
        #expect(reopened.selectedRun == nil)
        #expect(reopened.builderDispatchPending)
        #expect(reopened.isBusy)
        #expect(reopened.errorText?.contains("cannot be verified") == true)
        #expect(try store.load(key: "new")?["builder_session"] != nil)
        #expect(useCase.buildCount == 1)
    }

    @Test(arguments: ["executable", "environment"])
    func givenLateBuildAcknowledgement_whenRuntimeSwitches_thenOriginalBindingRemainsReserved(change: String) async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running"); useCase.delayBuild = true
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow(); first.name = "Late acknowledgement"; first.generate()
        await waitUntil { useCase.pendingBuild != nil }
        useCase.runtimeToken = runtime(change: change)
        // when
        useCase.finishBuild()
        await waitUntil { useCase.agentUsageAcknowledgements == 1 }
        // then
        #expect(first.selectedRun == nil)
        #expect(first.builderDispatchPending)
        let stored = try store.load(key: "new")
        let session = try #require(stored?["builder_session"]?.objectValue)
        #expect(WorkflowBuilderBinding(raw: session["runtime_binding"]?.objectValue) == WorkflowBuilderBinding(runtime(change: "original")))
        #expect(useCase.buildCount == 1)
    }

    @Test
    func givenStoredSession_whenOnlyEnvironmentChanges_thenReopenUsesCurrentRuntimeAndRestoresRun() async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running")
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow(); first.name = "Environment change"; first.prepareGeneration(refining: true); first.generate()
        await waitUntil { first.selectedRun?.id == "builder-run" && !first.isBusy }
        useCase.runtimeToken = runtime(change: "environment")
        // when
        let reopened = vm(store: store, useCase: useCase)
        reopened.newWorkflow()
        // then
        #expect(reopened.selectedRun?.id == "builder-run")
        #expect(!reopened.builderDispatchPending)
        #expect(reopened.builderRuntime == useCase.runtimeToken)
        #expect(useCase.buildCount == 1)
    }

    @Test
    func givenPendingAttempt_whenNewerReservationReplacesDraft_thenOldAcknowledgementCannotOverwriteIt() async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running"); useCase.delayBuild = true
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow(); first.name = "Stale acknowledgement"; first.generate()
        await waitUntil { useCase.pendingBuild != nil }
        let stored = try store.load(key: "new")
        var draft = try #require(stored)
        let newerAttempt = WorkflowBuilderAttempt(draftID: first.draftID, runtime: try #require(useCase.runtimeToken))
        draft["builder_dispatch_attempt"] = .object(newerAttempt.raw)
        try store.save(draft, key: "new")
        // when
        useCase.finishBuild()
        await waitUntil { useCase.buildReturned }
        // then
        #expect(try store.load(key: "new")?["builder_dispatch_attempt"]?.objectValue?["id"]?.stringValue == newerAttempt.id.uuidString)
        #expect(first.selectedRun == nil)
    }

    @Test
    func givenLateAcknowledgementAndDraftWriteFailure_whenEditorHasMoved_thenNewerErrorAndReservationSurvive() async throws {
        // given
        let base = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = ToggleFailingBuilderDraftStore(base: base)
        let useCase = BuilderSessionUseCase(status: "running"); useCase.delayBuild = true
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow(); first.name = "Original editor"; first.generate()
        await waitUntil { useCase.pendingBuild != nil }
        first.name = "Newer editor"
        first.errorText = "Newer editor error"
        store.failSaves = true
        // when
        useCase.finishBuild()
        await waitUntil { !first.operationBusy && useCase.buildReturned }
        // then
        #expect(first.errorText == "Newer editor error")
        #expect(first.selectedRun == nil)
        #expect(first.builderDispatchPending)
        #expect(try base.load(key: "new")?["builder_dispatch_pending"] == .bool(true))
        #expect(try base.load(key: "new")?["builder_dispatch_attempt"] != nil)
    }

    @Test
    func givenAdoptedBuilderRun_whenRuntimeChangesOrDisappears_thenAssociationIsDroppedAndDraftReserved() async throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let useCase = BuilderSessionUseCase(status: "running")
        let first = vm(store: store, useCase: useCase)
        first.newWorkflow(); first.name = "Runtime loss"; first.prepareGeneration(refining: true); first.generate()
        await waitUntil { first.selectedRun?.id == "builder-run" && !first.isBusy }
        // when
        useCase.runtimeToken = nil
        let allowed = first.validateBuilderRuntime()
        // then
        #expect(!allowed)
        #expect(first.selectedRun == nil)
        #expect(first.builderDispatchPending)
        #expect(try store.load(key: "new")?["builder_session"] != nil)
        #expect(first.errorText?.contains("changed or is unavailable") == true)
    }

    @Test
    func givenLegacyBuilderMetadata_whenSavingOrRekeyingDraft_thenReservationIsPreserved() throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let draftID = UUID()
        try store.save(["draft_id": .string(draftID.uuidString), "name": .string("Legacy"),
                        "definition": .object(WorkflowVM.starterDefinition()), "saved_definition": .object([:]),
                        "revision": .number(0), "builder_dispatch_pending": .bool(true),
                        "builder_dispatch_owner": .string("previous-process")], key: "new")
        let useCase = BuilderSessionUseCase(status: "running")
        let restored = vm(store: store, useCase: useCase); restored.newWorkflow()
        restored.name = "Renamed"
        // when
        #expect(restored.persistDraft()) // ordinary persistence keeps opaque legacy reservation fields
        restored.loadedName = restored.name
        WorkflowDraftCompletion.completed[restored.draftID] = WorkflowDraftCompletion(
            name: "Renamed", revision: 1, submitted: WorkflowVM.starterDefinition(), saved: WorkflowVM.starterDefinition())
        defer { WorkflowDraftCompletion.completed.removeValue(forKey: restored.draftID) }
        #expect(!restored.persistDraft()) // a late save completion cannot adopt or clean up a reserved draft
        restored.finishDraftSave(previousKey: "new")
        // then
        #expect(try store.load(key: "new")?["builder_dispatch_pending"] == .bool(true))
        #expect(try store.load(key: "new")?["builder_dispatch_owner"]?.stringValue == "previous-process")
        #expect(try store.load(key: "saved:Renamed") == nil)
        #expect(restored.errorText?.contains("must be resolved") == true)
    }

    @Test
    func givenLegacyBuilderSessionWithoutBinding_whenReopening_thenRawSessionIsPreservedWithoutRestoringRun() throws {
        // given
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let draftID = UUID()
        let legacySession: [String: JSONValue] = ["run": .object(["workflow_run_id": .string("old-run"),
            "kind": .string("builder"), "status": .string("running")]), "context": .object(["name": .string("Legacy")])]
        try store.save(["draft_id": .string(draftID.uuidString), "name": .string("Legacy"),
                        "definition": .object(WorkflowVM.starterDefinition()), "saved_definition": .object([:]),
                        "revision": .number(0), "builder_session": .object(legacySession)], key: "new")
        let useCase = BuilderSessionUseCase(status: "running")
        let restored = vm(store: store, useCase: useCase)
        // when
        restored.newWorkflow()
        #expect(restored.persistDraft())
        // then
        #expect(restored.selectedRun == nil)
        #expect(restored.builderDispatchPending)
        #expect(restored.isBusy)
        #expect(restored.errorText?.contains("cannot be verified") == true)
        #expect(try store.load(key: "new")?["builder_session"]?.objectValue == legacySession)
        #expect(useCase.buildCount == 0)
    }

}

@MainActor
private final class ToggleFailingBuilderDraftStore: WorkflowDraftStoring {
    let base: WorkflowDraftStore
    var failSaves = false
    init(base: WorkflowDraftStore) { self.base = base }
    func load(key: String) throws -> [String: JSONValue]? { try base.load(key: key) }
    func save(_ draft: [String: JSONValue], key: String) throws {
        if failSaves { throw CocoaError(.fileWriteUnknown) }
        try base.save(draft, key: key)
    }

    func remove(key: String) throws { try base.remove(key: key) }
}

// MARK: - BuilderSessionUseCase

private func runtime(change: String) -> QualificationRuntimeToken {
    let base = CtlClient(executable: "/fixture/ctl", environment: [:])
    switch change {
    case "executable": return QualificationRuntimeToken(client: CtlClient(executable: "/other/ctl", environment: [:]))
    case "state-root":
        return QualificationRuntimeToken(client: CtlClient(executable: base.executable, environment: ["HOME": "/other"],
            compatibilityContext: RuntimeCompatibilityContext(expectedStateRoot: "/other/.harflow")))
    case "product-version":
        return QualificationRuntimeToken(client: CtlClient(executable: base.executable, environment: [:],
            compatibilityContext: RuntimeCompatibilityContext(expectedStateRoot: base.compatibilityContext.expectedStateRoot,
                                                               productVersion: "99.0.0")))
    case "environment": return QualificationRuntimeToken(client: CtlClient(executable: base.executable, environment: ["HARFLOW_TEST_SWITCH": "changed"]))
    default: return QualificationRuntimeToken(client: base)
    }
}

@MainActor
final class BuilderSessionUseCase: WorkflowUseCase, @unchecked Sendable {
    var status: String
    var hostedRun: [String: JSONValue]?
    var delayBuild = false
    var buildCount = 0
    var buildResponse = "success"
    var runtimeToken: QualificationRuntimeToken? = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
    var pendingBuild: CheckedContinuation<[String: JSONValue], Never>?
    var buildReturned = false
    var agentUsageAcknowledgements = 0
    init(status: String) { self.status = status }
    func activityRuntime() throws -> QualificationRuntimeToken {
        guard let runtimeToken else { throw CocoaError(.fileReadUnknown) }
        return runtimeToken
    }

    var backendIDs: [String] { ["codex"] }
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
    func refreshTasks() async {}
    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { ["valid": .bool(true)] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int, expectedWorkflowID _: String?) async throws -> [String: JSONValue] { [:] }
    func command(_ command: String, options _: [String], positionals _: [String], runtime _: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        if command == "build" {
            buildCount += 1
            if buildResponse == "failure" { throw CocoaError(.fileReadUnknown) }
            if buildResponse == "missing-id" { return [:] }
            if delayBuild {
                let response = await withCheckedContinuation { pendingBuild = $0 }
                buildReturned = true
                return response
            }
            return ["workflow_run_id": .string("builder-run")]
        }
        if command == "status", let hostedRun { return ["run": .object(hostedRun)] }
        if command == "status" {
            var proposal = WorkflowVM.starterDefinition()
            proposal["description"] = .string("Agent proposal")
            return ["run": .object(["workflow_run_id": .string("builder-run"), "kind": .string("builder"), "status": .string(status),
                                    "workflow_name": .string("Saved workflow"), "editing_definition": .object(WorkflowVM.starterDefinition()),
                                    "generated_definition": .object(proposal)])]
        }
        return [:]
    }

    func recordAgentUsage(_: AgentUsageIdentity, acknowledgementID _: String) async { agentUsageAcknowledgements += 1 }

    func finishBuild() {
        pendingBuild?.resume(returning: ["workflow_run_id": .string("builder-run")])
        pendingBuild = nil
    }
}
