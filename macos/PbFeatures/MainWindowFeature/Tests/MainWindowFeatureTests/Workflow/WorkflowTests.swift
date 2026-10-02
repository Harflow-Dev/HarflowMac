import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

// MARK: - WorkflowTests

@MainActor
@Suite struct WorkflowTests {
    /// Fixtures emitted by Python validate_definition/create_run, not a Swift-only invented schema.
    func fixture(_ name: String) throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
    }

    func makeVM() -> (sut: WorkflowVM, useCase: MockWorkflowUseCase) {
        let useCase = MockWorkflowUseCase()
        let routing = MockWorkflowRouting()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(routing).chooseDirectory().willReturn(nil)
        given(routing).selectTask(.any).willReturn()
        given(routing).didSaveWorkflow(name: .any).willReturn()
        given(routing).openWorkflowEditor(name: .any).willReturn()
        return (WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut), useCase)
    }

    @Test func givenCanonicalEngineDefinition_whenMapped_thenCanvasReadsConnectionsTitlesRolesAndCandidates() throws {
        // given
        let raw = try fixture("definition")
        // when
        let record = WorkflowRecord(raw: raw)
        let nodes = WorkflowJSON.nodes(record.definition)
        let edges = WorkflowJSON.edges(record.definition)
        // then
        #expect(record.id == "implement-review")
        #expect(nodes.map(\.name) == ["start", "Plan", "Implement", "Review", "Run tests", "end"])
        #expect(nodes.filter { $0.type == "agent" }.map(\.role) == ["planning", "implementation", "review", "task"])
        #expect(nodes.first { $0.id == "implement" }?.backend == "codex")
        #expect(edges.count == 7)
        #expect(edges.first { $0.id == "review-fix" }?.isBackward == true)
        #expect(raw["orchestrator"]?["backend"]?.stringValue == "codex")
    }

    @Test func givenStartAndEndAlreadyOnCanvas_whenDroppedAgain_thenDuplicatesAreIgnored() {
        // given
        let vm = makeVM().sut
        vm.definition = WorkflowVM.starterDefinition()
        let original = vm.nodes

        // when
        vm.addNode("start", at: CGPoint(x: 200, y: 200))
        vm.addNode("end", at: CGPoint(x: 300, y: 300))

        // then
        #expect(vm.nodes == original)
        #expect(vm.nodes.filter { $0.type == "start" }.count == 1)
        #expect(vm.nodes.filter { $0.type == "end" }.count == 1)
    }

    @Test func givenCanonicalEngineRun_whenMapped_thenRunOwnsImmutableCanvasAndChecklistState() throws {
        // given
        var raw = try fixture("run")
        raw["tasks"] = .array([.object(["id": .string("one"), "title": .string("Implement"), "status": .string("completed")])])
        // when
        let run = WorkflowRunModel(raw: raw)
        let harness = makeVM()
        harness.sut.selectedRun = run
        // then
        #expect(!run.id.isEmpty)
        #expect(run.name == "implement-review")
        #expect(harness.sut.nodes.count == 6)
        #expect(run.tasks.first?["status"] == .string("completed"))
        #expect(!harness.sut.canSave)
    }

    @Test func givenWorkerAndDecisionActivations_whenMappingStatus_thenOnlyWorkerCountsAsAnAttempt() {
        // given
        let harness = makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["status": .string("running"), "activations": .array([
            .object(["id": .string("worker"), "node_id": .string("implement"), "role": .string("node"), "status": .string("completed")]),
            .object(["id": .string("decision"), "node_id": .string("implement"), "role": .string("orchestrator"), "status": .string("running")])])])
        // when
        let status = harness.sut.nodeStatus("implement")
        // then
        #expect(status == "completed")
        #expect(harness.sut.nodeAttempt("implement") == 1)
    }

    @Test func givenLoadedRevision_whenSaving_thenExpectedRevisionAndCanonicalDefinitionGoToRepository() async throws {
        // given
        let raw = try fixture("definition")
        let harness = makeVM()
        harness.sut.definition = raw
        harness.sut.name = "implement-review"
        harness.sut.revision = 7
        var canonical = raw
        canonical["nodes"] = .array(WorkflowJSON.objects(raw["nodes"]).map { node in
            var node = node
            node["branch_mode"] = .string("auto")
            return .object(node)
        })
        var saved = canonical
        saved["revision"] = .number(8)
        given(harness.useCase).save(name: .value("implement-review"), definition: .value(.object(canonical)), expectedRevision: .value(7)).willReturn(saved)
        given(harness.useCase).command(.value("list"), options: .any, positionals: .any).willReturn(["workflows": .array([])])
        given(harness.useCase).command(.value("list-runs"), options: .any, positionals: .any).willReturn(["runs": .array([])])
        // when
        await waitUntil { harness.sut.canSave }
        harness.sut.save()
        await waitUntil { !harness.sut.isBusy }
        // then
        #expect(harness.sut.revision == 8)
        #expect(harness.sut.definition["connections"] == saved["connections"])
        #expect(harness.sut.errorText == nil)
    }

    @Test func givenUnalignedCoordinates_whenMovingOrAdding_thenStoredPositionsSnapToFineGrid() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        let id = harness.sut.nodes[0].id
        // when
        harness.sut.moveNode(id, to: CGPoint(x: 117, y: -8))
        harness.sut.addNode("task", at: CGPoint(x: 213, y: 267))
        // then
        #expect(harness.sut.nodes.first { $0.id == id }?.position == CGPoint(x: 120, y: 0))
        #expect(harness.sut.nodes.last?.position == CGPoint(x: 210, y: 270))
    }

    @Test func givenInputPorts_whenFindingDropTarget_thenUsesToleranceAndRejectsStartAndSelf() {
        // given
        let nodes = WorkflowJSON.nodes(WorkflowVM.starterDefinition())
        let source = nodes[0]
        let target = nodes[1]
        let input = WorkflowCanvasGeometry.input(target)
        // when / then
        #expect(WorkflowCanvasGeometry.target(at: CGPoint(x: input.x + 20, y: input.y), sourceID: source.id, nodes: nodes)?.id == target.id)
        #expect(WorkflowCanvasGeometry.target(at: CGPoint(x: input.x + 23, y: input.y), sourceID: source.id, nodes: nodes) == nil)
        #expect(WorkflowCanvasGeometry.target(at: input, sourceID: target.id, nodes: nodes) == nil)
        #expect(WorkflowCanvasGeometry.target(at: WorkflowCanvasGeometry.input(source), sourceID: target.id, nodes: nodes) == nil)
    }

    @Test func givenConnections_whenConnectingInvalidOrRepeatedPorts_thenGraphRemainsUnchanged() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        let nodes = harness.sut.nodes
        let count = harness.sut.edges.count
        // when
        for (source, target) in [(nodes[0].id, nodes[1].id), (nodes[1].id, nodes[0].id), (nodes.last!.id, nodes[1].id)] {
            harness.sut.connectionSourceID = source
            harness.sut.selectNode(target)
        }
        // then
        #expect(harness.sut.edges.count == count)
    }

    @Test func givenSelectedNode_whenDeleting_thenRemovesItsConnectionsAndPendingConnectionSource() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        let id = harness.sut.nodes[1].id
        harness.sut.selectedNodeID = id
        harness.sut.connectionSourceID = id
        // when
        harness.sut.deleteSelected()
        // then
        #expect(!harness.sut.nodes.contains { $0.id == id })
        #expect(!harness.sut.edges.contains { $0.source == id || $0.target == id })
        #expect(harness.sut.connectionSourceID == nil)
    }

    @Test func givenReadOnlyRun_whenMutatingCanvas_thenDefinitionRemainsUnchanged() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        let original = harness.sut.definition
        harness.sut.selectedNodeID = harness.sut.nodes[0].id
        harness.sut.selectedRun = WorkflowRunModel(raw: [:])
        // when
        harness.sut.deleteSelected()
        harness.sut.addNode("task")
        harness.sut.moveNode("start", to: CGPoint(x: 123, y: 456))
        harness.sut.updateNode("start", key: "prompt", value: .string("AX setter must not mutate"))
        harness.sut.updateNode("work", key: "instructions", value: .string("AX setter must not mutate"))
        harness.sut.updateEdge(harness.sut.edges.first?.id ?? "", key: "condition", value: .string("AX setter must not mutate"))
        // then
        #expect(harness.sut.definition == original)
    }

    @Test func givenValidatedGraph_whenDraftChanges_thenSaveRemainsEnabledWhileRevalidated() async {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        harness.sut.name = "valid-workflow"
        await waitUntil { harness.sut.validationMessage == nil }
        // when
        harness.sut.moveNode("start", to: CGPoint(x: 123, y: 123))
        // then
        #expect(harness.sut.canSave)
        #expect(harness.sut.validationMessage == "Checking workflow…")
        await waitUntil { harness.sut.validationMessage == nil }
        harness.sut.name = ""
        #expect(harness.sut.canSave)
    }

    @Test func givenDelayedValidation_whenDraftChanges_thenOldSuccessCannotClearNewWarning() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "old-name"
        await waitUntil { useCase.requests.count == 1 }
        // when
        vm.name = "new-name"
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        // then
        #expect(vm.canSave)
        await waitUntil { useCase.requests.count == 2 }
        #expect(useCase.requests[1]["name"] == .string("new-name"))
        useCase.finish(1, result: .success(["valid": .bool(false), "error": .string("No end node")]))
        await waitUntil { vm.validationMessage == "No end node" }
        #expect(vm.canSave)
    }

    @Test func givenValidationFailureAndDisappearance_whenResponsesArrive_thenSaveStaysClickable() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "workflow"
        await waitUntil { useCase.requests.count == 1 }
        // when
        useCase.finish(0, result: .failure(ToolError.notFound(tool: "polybridge-ctl", searched: [])))
        await waitUntil { vm.validationMessage?.hasPrefix("Unable to validate workflow.") == true }
        vm.name = "renamed"
        await waitUntil { useCase.requests.count == 2 }
        vm.didDisappear()
        useCase.finish(1, result: .success(["valid": .bool(true)]))
        // then
        #expect(vm.canSave)
        #expect(vm.errorText == nil)
    }

    @Test func givenSaveInFlight_whenOpeningNewDraft_thenOldSaveResponseCannotReplaceDraftMetadata() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "original"
        await waitUntil { useCase.requests.count == 1 }
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await waitUntil { vm.validationMessage == nil }
        vm.save()
        await waitUntil { useCase.savedRequests.count == 1 }
        // when
        vm.newWorkflow()
        let freshDraft = vm.definition
        var saved = useCase.savedRequests[0]
        saved["revision"] = .number(12)
        useCase.finishSave(saved)
        await waitUntil { !vm.isBusy }
        // then
        #expect(vm.name.isEmpty)
        #expect(vm.loadedName.isEmpty)
        #expect(vm.revision == 0)
        #expect(vm.definition == freshDraft)
        #expect(vm.savedDefinition.isEmpty)
        #expect(vm.canSave)
    }

    @Test func givenReviewStep_whenRenamingTitle_thenRoleSettingsAndConnectionsRemainUnchanged() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        let original = WorkflowJSON.objects(harness.sut.definition["nodes"]).first { $0["id"] == .string("review") }!
        let connections = harness.sut.definition["connections"]
        // when
        harness.sut.updateNode("review", key: "title", value: .string("Tests Review"))
        // then
        var expected = original
        expected["title"] = .string("Tests Review")
        #expect(WorkflowJSON.objects(harness.sut.definition["nodes"]).first { $0["id"] == .string("review") } == expected)
        #expect(harness.sut.definition["connections"] == connections)
        #expect(harness.sut.nodes.first { $0.id == "review" }?.role == "review")
    }

    @Test func givenDotPorts_whenDrawingConnection_thenEndpointsTouchOuterRimsWithoutChangingHitCenters() {
        // given
        let nodes = WorkflowJSON.nodes(WorkflowVM.starterDefinition())
        let source = nodes[0]
        let target = nodes[1]
        // when / then
        #expect(WorkflowCanvasGeometry.connectionOutput(source).x == WorkflowCanvasGeometry.output(source).x + 5.25)
        #expect(WorkflowCanvasGeometry.connectionInput(target).x == WorkflowCanvasGeometry.input(target).x - 5.25)
        #expect(WorkflowCanvasGeometry.connectionInput(target, highlighted: true).x == WorkflowCanvasGeometry.input(target).x - 6.75)
        #expect(WorkflowCanvasGeometry.target(at: WorkflowCanvasGeometry.input(target), sourceID: source.id, nodes: nodes)?.id == target.id)
    }

    @Test func givenStartEndAndAgentSteps_whenMappingGeometry_thenCompactPortsUseTheirActualSquareSize() {
        // given
        let nodes = WorkflowJSON.nodes(WorkflowVM.starterDefinition())
        let start = nodes[0]
        let agent = nodes[1]
        let end = nodes.last!
        // when / then
        #expect(WorkflowCanvasGeometry.size(start) == CGSize(width: 72, height: 72))
        #expect(WorkflowCanvasGeometry.size(end) == CGSize(width: 72, height: 72))
        #expect(WorkflowCanvasGeometry.size(agent) == CGSize(width: 200, height: 92))
        #expect(WorkflowCanvasGeometry.output(start) == CGPoint(x: start.position.x + 72, y: start.position.y + 36))
        #expect(WorkflowCanvasGeometry.input(end) == CGPoint(x: end.position.x, y: end.position.y + 36))
        #expect(WorkflowCanvasGeometry.center(agent) == CGPoint(x: agent.position.x + 100, y: agent.position.y + 46))
    }

    @Test func givenEditorLoadInFlight_whenDraftChangesOrViewDisappears_thenStaleDefinitionCannotReplaceDraft() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        var loaded = WorkflowVM.starterDefinition()
        loaded["name"] = .string("old-workflow")
        // when / then
        for disappears in [false, true] {
            vm.selectWorkflow(WorkflowRecord(raw: ["name": .string("old-workflow")]))
            await waitUntil { useCase.pendingLoad != nil }
            if disappears { vm.didDisappear() } else { vm.newWorkflow() }
            let draft = vm.definition
            useCase.finishLoad(loaded)
            await waitUntil { !vm.isBusy }
            #expect(vm.definition == draft)
            #expect(vm.loadedName.isEmpty)
        }
    }

    @Test func givenFirstSaveRefreshInFlight_whenEditingDraft_thenNavigationDoesNotDiscardNewerEdits() async {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        useCase.delayRefresh = true
        let routing = MockWorkflowRouting()
        given(routing).didSaveWorkflow(name: .any).willReturn()
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut)
        vm.definition = WorkflowVM.starterDefinition()
        vm.name = "workflow"
        await waitUntil { useCase.requests.count == 1 }
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await waitUntil { vm.validationMessage == nil }
        vm.save()
        await waitUntil { useCase.savedRequests.count == 1 }
        var saved = useCase.savedRequests[0]
        saved["revision"] = .number(4)
        useCase.finishSave(saved)
        await waitUntil { useCase.pendingRefresh != nil }
        // when
        vm.updateNode("review", key: "title", value: .string("Tests Review"))
        useCase.finishRefresh()
        await waitUntil { !vm.isBusy }
        // then
        #expect(vm.nodes.first { $0.id == "review" }?.name == "Tests Review")
        #expect(vm.hasUnsavedChanges)
        #expect(vm.revision == 4)
        verify(routing).didSaveWorkflow(name: .any).called(0)
        vm.didDisappear()
        useCase.finishAllValidations()
    }

    @Test func givenEachStepRole_whenAdding_thenUsesRoleDefaultAccessAndAllowedChoices() {
        // given
        let harness = makeVM()
        // when / then
        for (role, access) in [("planning", "read_only"), ("review", "read_only"), ("implementation", "write_in_repo"), ("task", "publish")] {
            harness.sut.addNode(role)
            #expect(harness.sut.nodes.last?.raw["freedom"] == .string(access))
            #expect(WorkflowAccess.allowedLevels(for: role).contains("unrestricted"))
            #expect(WorkflowAccess.allowedLevels(for: role).contains("read_only") == (role != "implementation"))
        }
    }

    @Test func givenReadOnlyPlanningStep_whenChangingToImplementation_thenNormalizesAccessAndRejectsReadOnly() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        // when
        harness.sut.updateNode("planning", key: "role", value: .string("implementation"))
        harness.sut.updateNode("planning", key: "freedom", value: .string("read_only"))
        // then
        #expect(harness.sut.nodes.first { $0.id == "planning" }?.raw["freedom"] == .string("write_in_repo"))
        // when
        harness.sut.updateNode("planning", key: "freedom", value: .string("unrestricted"))
        harness.sut.updateNode("planning", key: "role", value: .string("review"))
        // then
        #expect(harness.sut.nodes.first { $0.id == "planning" }?.raw["freedom"] == .string("unrestricted"))
    }

    @Test func givenEmptyName_whenSaving_thenSharedAlertExplainsAndNothingPersists() async {
        let harness = makeVM()
        harness.sut.newWorkflow()
        var alert: AlertContent?
        let subscription = harness.sut.objectDidPublishViewEvent.publisher.sink { if case .alert(let value) = $0 { alert = value } }
        #expect(harness.sut.canSave)
        harness.sut.save()
        await waitUntil { alert != nil }
        #expect(alert?.description == "Enter a workflow name.")
        verify(harness.useCase).save(name: .any, definition: .any, expectedRevision: .any).called(0)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenInvalidGraph_whenSaving_thenCanonicalWarningShowsWithoutPersistence() async {
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.newWorkflow()
        vm.name = "draft"
        var alert: AlertContent?
        let subscription = vm.objectDidPublishViewEvent.publisher.sink { if case .alert(let value) = $0 { alert = value } }
        #expect(vm.canSave)
        vm.save()
        #expect(vm.isBusy)
        await waitUntil { useCase.requests.count == 1 }
        useCase.finish(0, result: .success(["valid": .bool(false), "error": .string("Orphan node has no outgoing connection")]))
        await waitUntil { alert != nil && !vm.isBusy }
        #expect(alert?.description == "Orphan node has no outgoing connection")
        #expect(useCase.savedRequests.isEmpty)
        #expect(vm.canSave)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenPendingValidGraph_whenSaveClicked_thenValidatesExactSnapshotBeforePersisting() async {
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.newWorkflow()
        vm.name = "pending-draft"
        vm.save()
        await waitUntil { useCase.requests.count == 1 }
        #expect(useCase.requests[0]["name"] == .string("pending-draft"))
        #expect(useCase.savedRequests.isEmpty)
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await waitUntil { useCase.savedRequests.count == 1 }
        #expect(useCase.savedRequests[0] == useCase.requests[0])
        var response = useCase.savedRequests[0]
        response["revision"] = .number(1)
        // Suppress first-save routing by editing while the save is in flight.
        vm.updateNode("review", key: "title", value: .string("New review title"))
        useCase.finishSave(response)
        await waitUntil { !vm.isBusy }
        vm.didDisappear()
        useCase.finishAllValidations()
    }

    @Test(arguments: ["definition", "name", "revision", "new-draft", "disappear"])
    func givenSaveValidationInFlight_whenDraftChanges_thenStaleSuccessCannotPersist(_ change: String) async {
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.newWorkflow()
        vm.name = "draft"
        vm.save()
        await waitUntil { useCase.requests.count == 1 }
        switch change {
        case "name": vm.name = "renamed"
        case "revision": vm.revision = 10
        case "new-draft": vm.newWorkflow()
        case "disappear": vm.didDisappear()
        default: vm.updateNode("review", key: "title", value: .string("Changed during validation"))
        }
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await waitUntil { !vm.isBusy }
        #expect(useCase.savedRequests.isEmpty)
        #expect(vm.loadedName.isEmpty)
        vm.didDisappear()
        useCase.finishAllValidations()
    }

    @Test func givenValidatedSnappedNode_whenMovedWithinSameGridCell_thenValidationRemainsCached() async {
        let harness = makeVM()
        harness.sut.newWorkflow()
        harness.sut.name = "draft"
        harness.sut.moveNode("start", to: CGPoint(x: 80, y: 80))
        await waitUntil { harness.sut.validationMessage == nil }
        let before = harness.sut.definition
        harness.sut.moveNode("start", to: CGPoint(x: 81, y: 81))
        #expect(harness.sut.definition == before)
        #expect(harness.sut.validationMessage == nil)
    }

    @Test func givenNewWorkflowOrAddedSteps_whenCreated_thenBranchingIsAutomatic() {
        let vm = makeVM().sut
        vm.newWorkflow()
        #expect(vm.selectedNode?.type == "start")
        #expect(vm.nodes.allSatisfy { $0.raw["branch_mode"] == .string("auto") })
        for kind in ["planning", "implementation", "review", "task"] {
            vm.addNode(kind)
            #expect(vm.nodes.last?.raw["branch_mode"] == .string("auto"))
        }
    }

    @Test func givenLegacyEditableModes_whenSaving_thenOnlySubmittedSnapshotUsesAutomaticBranching() async {
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        vm.newWorkflow()
        vm.name = "legacy"
        vm.updateNode("review", key: "branch_mode", value: .string("choose_one"))
        vm.save()
        await waitUntil { useCase.requests.count == 1 }
        #expect(vm.nodes.first { $0.id == "review" }?.raw["branch_mode"] == .string("choose_one"))
        #expect(WorkflowJSON.nodes(useCase.requests[0]).allSatisfy { $0.raw["branch_mode"] == .string("auto") })
        useCase.finish(0, result: .success(["valid": .bool(false), "error": .string("Stop before save")]))
        await waitUntil { !vm.isBusy }
        #expect(useCase.savedRequests.isEmpty)
        #expect(vm.nodes.first { $0.id == "review" }?.raw["branch_mode"] == .string("choose_one"))
    }

    @Test(arguments: ["claude", "vibe", "codex", "opencode", "antigravity"])
    func givenWorkflowCandidate_whenDefaultingTurnBudget_thenOnlyCapableBackendsUse100(_ backend: String) {
        let candidate = WorkflowCandidateSettings.make(backend: backend)
        let supported = ["claude", "vibe"].contains(backend)
        #expect(candidate["max_turns"] == (supported ? .number(100) : nil))
        #expect(WorkflowCandidateSettings.turnLimitText(candidate) == (supported ? "100" : ""))
        #expect(candidate["max_attempts"] == nil)
        #expect(candidate["max_transitions"] == nil)
    }

    @Test func givenExplicitWorkflowTurnLimit_whenEditingOrSwitchingBackend_thenPreservesSupportedLimitAndDropsUnsupportedCap() {
        let candidate: [String: JSONValue] = ["backend": .string("claude"), "max_turns": .number(12), "model": .string("opus")]
        #expect(WorkflowCandidateSettings.turnLimitText(candidate) == "12")
        let switched = WorkflowCandidateSettings.replacingBackend(in: candidate, with: "vibe")
        #expect(switched["max_turns"] == .number(12))
        #expect(switched["model"] == nil)
        let unsupported = WorkflowCandidateSettings.replacingBackend(in: switched, with: "codex")
        #expect(unsupported["max_turns"] == nil)
        #expect(WorkflowCandidateSettings.turnLimitText(unsupported).isEmpty)
        #expect(WorkflowCandidateSettings.replacingBackend(in: unsupported, with: "claude")["max_turns"] == .number(100))
    }

}

// MARK: - ControlledWorkflowValidationUseCase

@MainActor
private final class ControlledWorkflowValidationUseCase: WorkflowUseCase, @unchecked Sendable {
    var requests: [[String: JSONValue]] = []
    var savedRequests: [[String: JSONValue]] = []
    var delayRefresh = false
    var pendingRefresh: CheckedContinuation<[String: JSONValue], Never>?
    var pendingLoad: CheckedContinuation<[String: JSONValue], Never>?
    private var pendingSave: CheckedContinuation<[String: JSONValue], Never>?
    private var pending: [Int: CheckedContinuation<[String: JSONValue], any Error>] = [:]
    var backendIDs: [String] { ["codex"] }

    func validate(definition: JSONValue) async throws -> [String: JSONValue] {
        let index = requests.count
        requests.append(definition.objectValue ?? [:])
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func finish(_ index: Int, result: Result<[String: JSONValue], any Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func command(_ command: String, options _: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        if command == "list", delayRefresh {
            return await withCheckedContinuation { pendingRefresh = $0 }
        }
        guard command == "get" else { return [:] }
        return await withCheckedContinuation { pendingLoad = $0 }
    }

    func finishRefresh() {
        pendingRefresh?.resume(returning: [:])
        pendingRefresh = nil
    }

    func finishAllValidations() {
        for index in Array(pending.keys) { finish(index, result: .success(["valid": .bool(true)])) }
    }

    func finishLoad(_ response: [String: JSONValue]) {
        pendingLoad?.resume(returning: response)
        pendingLoad = nil
    }

    func save(name _: String, definition: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] {
        savedRequests.append(definition.objectValue ?? [:])
        return await withCheckedContinuation { pendingSave = $0 }
    }

    func finishSave(_ response: [String: JSONValue]) {
        pendingSave?.resume(returning: response)
        pendingSave = nil
    }

    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
