import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowTests selection

extension WorkflowTests {
    @Test func givenEditorSelection_whenSidebarDerivationRuns_thenSelectionAndDefaultInspectorRemain() async throws {
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)

        // Editor mode has no run snapshot, but selecting a node still schedules
        // the shared sidebar derivation. That work must not clear editor state.
        vm.selectNode(nodeID)
        await vm.sidebarTask?.value
        await waitUntil { vm.selectedNodeID == nodeID && vm.runSidebar.isDefault }

        #expect(vm.selectedNodeID == nodeID)
        #expect(vm.selectedNodeIDs == [nodeID])
        #expect(vm.runSidebar.isDefault)
    }

    @Test func givenBuilderRun_whenSelectingNode_thenBuilderSidebarStaysDefault() async throws {
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        vm.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("builder"),
            "kind": .string("builder"),
            "definition": .object(vm.definition)
        ])

        vm.selectNode(nodeID)
        await waitUntil { vm.selectedNodeID == nodeID && vm.runSidebar.isDefault }

        #expect(vm.selectedNodeID == nodeID)
        #expect(vm.runSidebar.isDefault)
    }

    @Test func givenRunSelection_whenReturningToEditor_thenSupersededRunResultCannotClearSelection() async throws {
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        vm.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("run"),
            "definition": .object(vm.definition),
            "activations": .array([])
        ])
        vm.selectNode(nodeID)
        let staleTask = vm.sidebarTask
        // Immediately leave run mode. The detached derivation for the run is
        // allowed to finish, but its generation and run identity are stale.
        vm.selectedRun = nil
        await staleTask?.value
        await waitUntil { vm.selectedNodeID == nodeID && vm.runSidebar.isDefault }

        #expect(vm.selectedNodeID == nodeID)
        #expect(vm.runSidebar.isDefault)
    }

    @Test func givenTwoSelectedRunNodes_whenSwitchingAwayAndBack_thenCachedActivityOwnerIsRestored() async throws {
        let vm = makeVM().sut
        let definition: [String: JSONValue] = [
            "nodes": .array([
                .object(["id": .string("a"), "type": .string("agent"), "title": .string("A")]),
                .object(["id": .string("b"), "type": .string("agent"), "title": .string("B")])
            ])
        ]
        vm.definition = definition
        vm.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("run"),
            "definition": .object(definition),
            "activations": .array([
                .object(["id": .string("a-attempt"), "role": .string("node"), "node_id": .string("a"),
                         "status": .string("completed"), "tasks": .array([.object(["task_id": .string("task-a")])])]),
                .object(["id": .string("b-attempt"), "role": .string("node"), "node_id": .string("b"),
                         "status": .string("completed"), "tasks": .array([.object(["task_id": .string("task-b")])])])
            ])
        ])

        vm.selectNode("a")
        await waitUntil { vm.runSidebar.node?["id"]?.stringValue == "a" && vm.selectedActivity != nil }
        let first = try #require(vm.selectedActivity)

        vm.selectNode("b")
        await waitUntil { vm.runSidebar.node?["id"]?.stringValue == "b" && vm.selectedActivity !== first }
        let second = try #require(vm.selectedActivity)

        vm.selectNode("a")
        await waitUntil { vm.runSidebar.node?["id"]?.stringValue == "a" && vm.selectedActivity === first }

        #expect(second !== first)
        #expect(vm.selectedActivity === first)
        #expect(vm.runSidebar.taskIDs == ["task-a"])
    }

    @Test func givenRunMode_whenSelectingSameNodeTwice_thenSidebarSelectionClears() async throws {
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectedRun = WorkflowRunModel(raw: [
            "id": .string("run"),
            "definition": .object(vm.definition),
            "activations": .array([])
        ])
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)

        vm.selectNode(nodeID)
        vm.selectNode(nodeID)
        try await waitUntil { vm.selectedNodeID == nil && vm.runSidebar.isDefault }

        #expect(vm.selectedNodeID == nil)
        #expect(vm.runSidebar.isDefault)
    }

    @Test func givenSelectedRunNode_whenRunSnapshotRemovesNode_thenSelectionReturnsToSummary() async throws {
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        vm.selectedRun = WorkflowRunModel(raw: [
            "id": .string("run"),
            "definition": .object(vm.definition),
            "activations": .array([])
        ])
        vm.selectedNodeID = nodeID
        try await waitUntil { vm.selectedNodeID == nodeID }

        vm.selectedRun = WorkflowRunModel(raw: [
            "id": .string("run"),
            "definition": .object(["nodes": .array([])]),
            "activations": .array([])
        ])
        try await waitUntil { vm.selectedNodeID == nil && vm.runSidebar.isDefault }

        #expect(vm.selectedNodeID == nil)
        #expect(vm.runSidebar.isDefault)
    }

    @Test func givenMultipleSelectedNodes_whenToggledAndDeleted_thenPrimaryAndIncidentEdgesStayConsistent() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectNodes(["implement", "review"], primary: "review")
        // when
        vm.toggleNode("review")
        #expect(vm.selectedNodeID == "implement")
        vm.toggleNode("review")
        vm.connectionSourceID = "implement"
        vm.deleteSelected()
        // then
        #expect(vm.selectedNodeIDs.isEmpty)
        #expect(vm.selectedNodeID == nil)
        #expect(vm.connectionSourceID == nil)
        #expect(!vm.nodes.contains { ["implement", "review"].contains($0.id) })
        #expect(!vm.edges.contains { ["implement", "review"].contains($0.source) || ["implement", "review"].contains($0.target) })
    }

    @Test func givenGroupPositions_whenMoved_thenSharedSnapAndBoundsPreserveOffsets() {
        // given
        let origins = ["a": CGPoint(x: 20, y: 30), "b": CGPoint(x: 95, y: 85)]
        // when
        let positive = WorkflowCanvasSelection.moved(origins: origins, delta: CGSize(width: 16, height: 24))
        let negative = WorkflowCanvasSelection.moved(origins: origins, delta: CGSize(width: -80, height: -90))
        // then
        #expect(positive["a"] == CGPoint(x: 40, y: 50))
        #expect(positive["b"] == CGPoint(x: 115, y: 105))
        #expect(negative["a"] == .zero)
        #expect(negative["b"] == CGPoint(x: 75, y: 55))
    }

    @Test func givenRunGraph_whenMovingOrDeletingMultipleNodes_thenDefinitionIsUnchanged() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectedRun = WorkflowRunModel(raw: [:])
        vm.selectNodes(["implement", "review"], primary: "implement")
        let before = vm.definition
        // when
        vm.moveNodes(["implement": .zero, "review": .zero])
        vm.deleteSelected()
        // then
        #expect(vm.definition == before)
    }

    @Test func givenGroupSelection_whenMovingBatch_thenBothPositionsUpdateTogether() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectNodes(["implement", "review"], primary: "implement")
        // when
        vm.moveNodes(["implement": CGPoint(x: 100, y: 200), "review": CGPoint(x: 300, y: 200)])
        // then
        #expect(vm.nodes.first { $0.id == "implement" }?.position == CGPoint(x: 100, y: 200))
        #expect(vm.nodes.first { $0.id == "review" }?.position == CGPoint(x: 300, y: 200))
        #expect(vm.selectedNodeIDs == ["implement", "review"])
        vm.selectedNodeID = nil
        #expect(vm.selectedNodeIDs.isEmpty)
    }

}
