import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowParallelGroupTests

@MainActor
struct WorkflowParallelGroupTests {
    private func boundary(_ id: String, _ type: String, _ group: String) -> JSONValue {
        .object(["id": .string(id), "type": .string(type), "parallel_group_id": .string(group)])
    }

    @Test func givenActiveAndReleasedGroups_whenMappingBoundaries_thenVisitedGroupsAreNotSkipped() {
        let split = WorkflowNodeModel(raw: ["id": .string("split"), "type": .string("parallel_start")])
        let end = WorkflowNodeModel(raw: ["id": .string("merge"), "type": .string("parallel_end")])
        let group: JSONValue = .object(["split_id": .string("split"), "join_id": .string("merge")])
        let running = WorkflowRunModel(raw: ["status": .string("running"), "joins": .object(["generation": group])])
        #expect(WorkflowParallelGroup.status(of: split, run: running) == "completed")
        #expect(WorkflowParallelGroup.status(of: end, run: running) == "waiting")
        let finished = WorkflowRunModel(raw: ["status": .string("completed"), "released_parallel_groups": .object(["generation": group])])
        #expect(WorkflowParallelGroup.status(of: split, run: finished) == "completed")
        #expect(WorkflowParallelGroup.status(of: end, run: finished) == "completed")
        let retrying = WorkflowRunModel(raw: ["status": .string("running"), "joins": .object(["new": group]),
                                             "released_parallel_groups": .object(["old": group])])
        #expect(WorkflowParallelGroup.status(of: end, run: retrying) == "waiting")
    }

    @Test func givenLegacyWorkflow_whenParallelGroupDropped_thenDefinitionAndSelectionRemainUnchanged() {
        // given
        let vm = WorkflowTests().makeVM().sut
        vm.newWorkflow()
        vm.definition["routing_mode"] = nil
        let original = vm.definition
        let selection = vm.selectedNodeIDs
        // when
        vm.addNode("parallel_group", at: CGPoint(x: 100, y: 200))
        // then
        #expect(vm.definition == original)
        #expect(vm.selectedNodeIDs == selection)
        #expect(vm.nodes.allSatisfy { !$0.isParallelBoundary })
    }

    @Test func givenNewDraft_whenParallelGroupDroppedAndUndone_thenBothBoundariesAreOneEdit() {
        // given
        let vm = WorkflowTests().makeVM().sut
        vm.newWorkflow()
        let original = vm.definition
        // when
        vm.addNode("parallel_group", at: CGPoint(x: 105, y: 203))
        let boundaries = vm.nodes.filter(\.isParallelBoundary)
        // then
        #expect(boundaries.count == 2)
        #expect(Set(boundaries.compactMap(\.parallelGroupID)).count == 1)
        #expect(boundaries.allSatisfy { $0.raw["agent"] == nil && $0.raw["freedom"] == nil })
        #expect(vm.selectedNodeIDs == Set(boundaries.map(\.id)))
        #expect(boundaries.first?.position == CGPoint(x: 110, y: 200))
        vm.undoWorkflowEdit()
        #expect(vm.definition == original)
    }

    @Test func givenNestedCopiedGroups_whenPasted_thenPairsHaveDistinctFreshGroupIdentities() throws {
        // given
        let payload: [String: JSONValue] = ["nodes": .array([
            boundary("outer-start", "parallel_start", "outer"), boundary("outer-end", "parallel_end", "outer"),
            boundary("inner-start", "parallel_start", "inner"), boundary("inner-end", "parallel_end", "inner")
        ])]
        // when
        let copied = try #require(WorkflowClipboard.pasted(payload, into: payload))
        let nodes = WorkflowJSON.nodes(copied.definition).filter { copied.ids.contains($0.id) }
        let groups = Dictionary(grouping: nodes, by: \.parallelGroupID)
        // then
        #expect(groups.count == 2)
        #expect(groups.values.allSatisfy { $0.count == 2 && Set($0.map(\.type)) == ["parallel_start", "parallel_end"] })
        #expect(nodes.allSatisfy { $0.parallelGroupID != "outer" && $0.parallelGroupID != "inner" })
    }

    @Test func givenPartialCopy_whenPasted_thenCannotPairWithOriginalBoundary() throws {
        // given
        let original: [String: JSONValue] = ["nodes": .array([
            boundary("s", "parallel_start", "group"), boundary("e", "parallel_end", "group")
        ])]
        let payload = try #require(WorkflowClipboard.payload(definition: original, selection: ["s"]))
        // when
        let copied = try #require(WorkflowClipboard.pasted(payload, into: original))
        let nodes = WorkflowJSON.nodes(copied.definition)
        let partial = try #require(nodes.first { copied.ids.contains($0.id) })
        // then
        #expect(partial.parallelGroupID != "group")
        #expect(WorkflowParallelGroup.partner(of: partial, nodes: nodes) == nil)
    }

    @Test func givenParallelGroupAndDownstreamNode_whenHighlighted_thenRegionStopsAtMatchingEnd() throws {
        // given
        let definition: [String: JSONValue] = ["nodes": .array([
            boundary("s", "parallel_start", "group"), boundary("e", "parallel_end", "group"),
            .object(["id": .string("branch"), "type": .string("agent")]), .object(["id": .string("next"), "type": .string("agent")])
        ]), "connections": .array([
            .object(["source": .string("s"), "target": .string("branch")]),
            .object(["source": .string("branch"), "target": .string("e")]),
            .object(["source": .string("e"), "target": .string("next")])
        ])]
        let nodes = WorkflowJSON.nodes(definition)
        // when
        let region = WorkflowParallelGroup.region(of: try #require(nodes.first), nodes: nodes, edges: WorkflowJSON.edges(definition))
        // then
        #expect(region == ["s", "branch", "e"])
        #expect(WorkflowVM.starterDefinition()["routing_mode"] == .string("explicit"))
    }
}
