@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowBranchSelectionTests

@MainActor
struct WorkflowBranchSelectionTests {
    private func node(_ id: String, type: String = "agent", group: String? = nil) -> JSONValue {
        var raw: [String: JSONValue] = ["id": .string(id), "type": .string(type), "title": .string(id)]
        if let group { raw["parallel_group_id"] = .string(group) }
        return .object(raw)
    }

    private func edge(_ id: String, _ source: String, _ target: String) -> JSONValue {
        .object(["id": .string(id), "source": .string(source), "target": .string(target)])
    }

    private var definition: [String: JSONValue] {
        ["nodes": .array([node("split", type: "parallel_start", group: "platforms"),
            node("merge", type: "parallel_end", group: "platforms"), node("ios", type: "workflow"), node("web"), node("web-review"), node("after")]),
         "connections": .array([edge("ios-entry", "split", "ios"), edge("web-entry", "split", "web"),
            edge("ios-end", "ios", "merge"), edge("web-review", "web", "web-review"),
            edge("web-end", "web-review", "merge"), edge("after", "merge", "after")])]
    }

    private func generation(_ sequence: Int, selected: [String], excluded: [String], 
                            stack: [String] = [], split: String = "split", join: String = "merge") -> JSONValue {
        .object(["split_id": .string(split), "join_id": .string(join), "selection_sequence": .number(Double(sequence)),
            "selected_connection_ids": .array(selected.map(JSONValue.string)), "excluded_connection_ids": .array(excluded.map(JSONValue.string)),
            "selection_reason": .string("Applies to iOS"), "selection_decision_id": .string("decision"), "expected": .number(Double(selected.count)),
            "stack": .array(stack.map(JSONValue.string))])
    }

    @Test func givenPriorChildInvocation_whenBranchReselectedOrExcluded_thenCanvasCannotOpenOldChild() {
        // given
        let activation: JSONValue = .object(["node_id": .string("ios"),
            "invocation": .object(["child_workflow_run_id": .string("old-child")]),
            "token": .object(["branch_ids": .object(["old": .string("ios")])])])
        for selected in [true, false] {
            let run = WorkflowRunModel(raw: ["definition": .object(definition),
                "joins": .object(["current": generation(8,
                    selected: [selected ? "ios-entry" : "web-entry"], excluded: [selected ? "web-entry" : "ios-entry"])]),
                "activations": .array([activation])])
            // when / then: history remains accessible, current canvas invocation does not leak.
            #expect(run.latestChildRunID(for: "ios") == "old-child")
            #expect(run.latestChildRunID(for: "ios", selection: WorkflowBranchSelection.build(run: run)) == nil)
        }
    }

    @Test func givenHistoricalGroupWithoutMembership_whenProjected_thenNoBranchIsInventedAsExcluded() {
        // given
        let run = WorkflowRunModel(raw: ["definition": .object(definition), "joins": .object([
            "legacy": .object(["split_id": .string("split"), "join_id": .string("merge"), "expected": .number(2)])
        ])])
        // when
        let selection = WorkflowBranchSelection.build(run: run)
        // then
        #expect(selection.excludedNodeIDs.isEmpty)
        #expect(selection.excludedEdgeIDs.isEmpty)
        #expect(WorkflowGroupInvocation.history(in: run).first?.hasSelection == false)
    }

    @Test func givenSubsetWithSerialWorkflowBranch_whenProjected_thenOnlyExcludedRegionIsDimmed() {
        // given
        let run = WorkflowRunModel(raw: ["definition": .object(definition), "joins": .object([
            "current": generation(8, selected: ["ios-entry"], excluded: ["web-entry"])
        ])])
        // when
        let selection = WorkflowBranchSelection.build(run: run)
        // then
        #expect(selection.excludedNodeIDs == ["web", "web-review"])
        #expect(selection.excludedEdgeIDs == ["web-entry", "web-review", "web-end"])
        #expect(selection.selectedEdgeIDs == ["ios-entry", "ios-end"])
        #expect(!selection.excludedNodeIDs.contains("merge"))
        #expect(!selection.excludedNodeIDs.contains("after"))
    }

    @Test func givenEarlierExecutedBranchExcludedNow_whenMappingStatus_thenItIsNotSelectedWithoutAnAttempt() {
        // given
        let vm = WorkflowTests().makeVM().sut
        vm.selectedRun = WorkflowRunModel(raw: ["status": .string("running"), "definition": .object(definition),
            "joins": .object(["current": generation(8, selected: ["ios-entry"], excluded: ["web-entry"])]),
            "activations": .array([.object(["node_id": .string("web"), "role": .string("node"), "status": .string("completed")])])])
        // when / then
        #expect(vm.nodeStatus("web") == "not_selected")
        #expect(vm.nodeAttempt("web") == 0)
        #expect(vm.nodeStatus("ios") == "pending")
    }

    @Test func givenNewLoopInvocation_whenProjected_thenOldExclusionsAndExecutionStatusDoNotLeak() throws {
        // given
        let old = generation(3, selected: ["web-entry"], excluded: ["ios-entry"])
        let current = generation(8, selected: ["ios-entry"], excluded: ["web-entry"])
        let vm = WorkflowTests().makeVM().sut
        vm.selectedRun = WorkflowRunModel(raw: ["status": .string("running"), "definition": .object(definition),
            "released_parallel_groups": .object(["old": old]), "joins": .object(["current": current]),
            "activations": .array([.object(["node_id": .string("ios"), "role": .string("node"), "status": .string("completed"),
                "token": .object(["branch_ids": .object(["old": .string("ios")])])])])])
        // when
        let run = try #require(vm.selectedRun)
        let history = WorkflowGroupInvocation.history(in: run, splitID: "split")
        // then
        #expect(vm.nodeStatus("ios") == "pending")
        #expect(vm.nodeStatus("web") == "not_selected")
        #expect(history.map(\.id) == ["current", "old"])
        #expect(history.allSatisfy { $0.reason == "Applies to iOS" && $0.raw["selection_decision_id"] == .string("decision") })
        #expect(history.last?.excludedConnectionIDs == ["ios-entry"])
    }

    @Test func givenNewOuterInvocationBeforeNestedSelection_whenProjected_thenOldNestedSelectionIsInactive() {
        // given
        var graph = definition
        graph["nodes"] = .array((graph["nodes"]?.arrayValue ?? []) + [node("inner", type: "parallel_start", group: "inner"),
            node("inner-end", type: "parallel_end", group: "inner"), node("inner-left"), node("inner-right")])
        graph["connections"] = .array((graph["connections"]?.arrayValue ?? []) + [edge("nested", "ios", "inner"),
            edge("left", "inner", "inner-left"), edge("right", "inner", "inner-right"),
            edge("left-end", "inner-left", "inner-end"), edge("right-end", "inner-right", "inner-end"), edge("nested-end", "inner-end", "merge")])
        let run = WorkflowRunModel(raw: ["definition": .object(graph), "joins": .object([
            "outer-new": generation(8, selected: ["ios-entry"], excluded: ["web-entry"])
        ]), "released_parallel_groups": .object([
            "outer-old": generation(2, selected: ["ios-entry"], excluded: ["web-entry"]),
            "inner-old": generation(3, selected: ["left"], excluded: ["right"], stack: ["outer-old"], split: "inner", join: "inner-end")
        ])])
        // when
        let selection = WorkflowBranchSelection.build(run: run)
        // then
        #expect(!selection.excludedNodeIDs.contains("inner-right"))
        #expect(selection.nodeGenerationIDs["inner-right"] == ["outer-new"])
        #expect(WorkflowParallelGroup.status(of: WorkflowNodeModel(raw: ["id": .string("inner"), "type": .string("parallel_start")]), run: run) == nil)
    }

    @Test func givenSingletonSelectedGroup_whenWaitingAndReleased_thenBoundaryStillRepresentsGroupInvocation() {
        // given
        let raw = generation(9, selected: ["ios-entry"], excluded: ["web-entry"])
        let boundary = WorkflowNodeModel(raw: ["id": .string("merge"), "type": .string("parallel_end")])
        let waiting = WorkflowRunModel(raw: ["status": .string("running"), "joins": .object(["singleton": raw])])
        let released = WorkflowRunModel(raw: ["status": .string("completed"), "released_parallel_groups": .object(["singleton": raw])])
        // when / then
        #expect(WorkflowParallelGroup.status(of: boundary, run: waiting) == "waiting")
        #expect(WorkflowParallelGroup.status(of: boundary, run: released) == "completed")
        #expect(WorkflowGroupInvocation.history(in: waiting).first?.expectedCount == 1)
    }

    @Test func givenSelectableBoundary_whenCopied_thenModeAndNaturalLanguageGuidanceArePreserved() throws {
        // given
        let original: [String: JSONValue] = ["nodes": .array([.object(["id": .string("split"), "type": .string("parallel_start"),
            "parallel_group_id": .string("platforms"), "branch_selection": .string("orchestrator"),
            "selection_guidance": .string("Affected platforms only")])])]
        let payload = try #require(WorkflowClipboard.payload(definition: original, selection: ["split"]))
        // when
        let pasted = try #require(WorkflowClipboard.pasted(payload, into: original))
        let copied = try #require(WorkflowJSON.nodes(pasted.definition).last)
        // then
        #expect(copied.raw["branch_selection"] == .string("orchestrator"))
        #expect(copied.raw["selection_guidance"] == .string("Affected platforms only"))
        #expect(copied.parallelGroupID != "platforms")
    }
}
