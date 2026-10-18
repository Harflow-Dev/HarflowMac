import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor
@Suite
struct WorkflowStandaloneTests {
    @Test
    func givenLegacyStartPrompt_whenNormalized_thenPromptMovesToOrchestratorAndIsRemoved() {
        let legacy: [String: JSONValue] = [
            "nodes": .array([.object([
                "id": .string("start"), "type": .string("start"), "prompt": .string("Legacy purpose")
            ])]),
            "orchestrator": .object(["backend": .string("codex")])
        ]

        let normalized = WorkflowStandalone.normalized(legacy)

        #expect(normalized["orchestrator"]?["instructions"] == .string("Legacy purpose"))
        #expect(normalized["nodes"]?.arrayValue?.first?.objectValue?["prompt"] == nil)
        #expect(WorkflowStandalone.normalized(normalized) == normalized)
    }

    @Test
    func givenExplicitOrchestratorInstructions_whenNormalized_thenExplicitValueWins() {
        let definition: [String: JSONValue] = [
            "nodes": .array([.object([
                "id": .string("start"), "type": .string("start"), "prompt": .string("Legacy")
            ])]),
            "orchestrator": .object([
                "backend": .string("codex"), "instructions": .string("Explicit")
            ])
        ]

        let normalized = WorkflowStandalone.normalized(definition)

        #expect(normalized["orchestrator"]?["instructions"] == .string("Explicit"))
    }

    @Test
    func givenRunCallMetadata_whenMapped_thenQualifiedNodeAndOriginAreExposed() {
        let call = WorkflowOnDemandCall(raw: [
            "id": .string("call-1"), "node_id": .string("owner:research"), "call_number": .number(1),
            "assignment": .string("Verify API"), "reason": .string("Need evidence"), "status": .string("succeeded"),
            "origin": .object(["kind": .string("node_question"), "title": .string("Plan")]),
            "result": .object(["summary": .string("API verified")])
        ])

        #expect(call.nodeID == "owner:research")
        #expect(call.number == 1)
        #expect(call.origin == "Called by the orchestrator while answering Plan's question")
        #expect(call.result.contains("API verified"))
    }

    @Test
    func givenStandaloneNode_whenCopied_thenCallConditionAndInstructionsRemainDistinct() {
        // given
        let definition: [String: JSONValue] = [
            "on_demand_nodes": .array([.object([
                "id": .string("research"), "title": .string("Researcher"),
                "instructions": .string("Return evidence only."),
                "call_condition": .string("Call when the answer needs current API facts."),
                "position": .object(["x": .number(20), "y": .number(40)])
            ])])
        ]

        // when
        let payload = WorkflowClipboard.payload(definition: definition, selection: ["research"])

        // then
        let copied = payload?["on_demand_nodes"]?.arrayValue?.first?.objectValue
        #expect(copied?["instructions"] == .string("Return evidence only."))
        #expect(copied?["call_condition"] == .string("Call when the answer needs current API facts."))
    }

    @Test
    func givenStandalonePayload_whenPasted_thenCopyHasNoGraphTopologyOrPosition() {
        // given
        let payload: [String: JSONValue] = [
            "on_demand_nodes": .array([.object([
                "id": .string("research"), "title": .string("Researcher"),
                "instructions": .string("Investigate."), "call_condition": .string("Call for uncertain facts."),
                "type": .string("agent"), "role": .string("research"),
                "position": .object(["x": .number(1), "y": .number(2)]),
                "connections": .array([])
            ])])
        ]

        // when
        let pasted = WorkflowClipboard.pasted(payload, into: ["on_demand_nodes": .array([])])

        // then
        let node = pasted?.definition["on_demand_nodes"]?.arrayValue?.first?.objectValue
        #expect(pasted?.ids.count == 1)
        #expect(node?["instructions"] == .string("Investigate."))
        #expect(node?["call_condition"] == .string("Call for uncertain facts."))
        #expect(node?["position"] == nil)
        #expect(node?["type"] == nil)
        #expect(node?["role"] == nil)
        #expect(node?["connections"] == nil)
    }

    @Test
    func givenEditor_whenAddingStandaloneNode_thenBlankNodeIsSelectedAndHasNoPosition() {
        // given
        let vm = WorkflowTests().makeVM().sut
        vm.definition = WorkflowVM.starterDefinition()

        // when
        vm.addOnDemandNode()

        // then
        let node = vm.selectedOnDemandNode
        #expect(node != nil)
        #expect(vm.selectedNodeID == node?.id)
        #expect(node?.instructions == "")
        #expect(node?.raw["call_condition"] == .string(""))
        #expect(node?.raw["position"] == nil)
        #expect(!vm.edges.contains { $0.source == node?.id || $0.target == node?.id })
    }

    @Test
    func givenEditor_whenDeletingOrchestratorSelection_thenDefinitionAndSelectionStayIntact() {
        // given
        let vm = WorkflowTests().makeVM().sut
        vm.definition = WorkflowVM.starterDefinition()
        vm.selectStandalone(WorkflowStandalone.orchestratorID)
        let before = vm.definition

        // when
        let deleted = vm.deleteStandaloneSelection()

        // then
        #expect(deleted)
        #expect(vm.definition == before)
        #expect(vm.selectedNodeID == WorkflowStandalone.orchestratorID)
    }

    @Test
    func givenStandaloneDraft_whenCallConditionChanges_thenDraftEqualityRequiresSave() {
        // given
        let base: [String: JSONValue] = ["on_demand_nodes": .array([.object([
            "id": .string("research"), "instructions": .string("Investigate."),
            "call_condition": .string("Call for facts.")
        ])])]
        var changed = base
        changed["on_demand_nodes"] = .array([.object([
            "id": .string("research"), "instructions": .string("Investigate."),
            "call_condition": .string("Call for current facts.")
        ])])

        // then
        #expect(!WorkflowDraftEquality.matches(base, changed))
    }

    @Test
    func givenRunWithOnDemandCatalog_whenSelectingQualifiedNode_thenCallsRemainScopedToThatNode() {
        // given
        let vm = WorkflowTests().makeVM().sut
        let raw: [String: JSONValue] = [
            "workflow_run_id": .string("root"), "status": .string("running"),
            "definition": .object(["on_demand_nodes": .array([])]),
            "on_demand_nodes": .array([
                .object(["node_id": .string("root:research"), "title": .string("Researcher")]),
                .object(["node_id": .string("root:writer"), "title": .string("Writer")])
            ]),
            "on_demand_calls": .array([
                .object(["id": .string("one"), "node_id": .string("root:research"), "call_number": .number(1)]),
                .object(["id": .string("two"), "node_id": .string("root:writer"), "call_number": .number(1)])
            ])
        ]
        vm.selectedRun = WorkflowRunModel(raw: raw)

        // when
        vm.selectStandalone("root:research")

        // then
        #expect(vm.selectedOnDemandNode?.id == "root:research")
        #expect(vm.selectedRun?.onDemandCalls.filter { $0.nodeID == vm.selectedNodeID }.count == 1)
    }

    @Test
    func givenBuilderPreview_whenExtractingStandaloneNodes_thenSelectionUsesDraftAndRemainsReadOnly() {
        // given: the builder has an authoritative empty draft while its source graph is available.
        let vm = WorkflowTests().makeVM().sut
        let sourceDefinition = WorkflowVM.starterDefinition()
        let emptyDraft: [String: JSONValue] = [
            "nodes": .array([]), "connections": .array([]), "on_demand_nodes": .array([])
        ]
        let initialRaw: [String: JSONValue] = [
            "workflow_run_id": .string("builder"), "kind": .string("builder"), "status": .string("running"),
            "editing_definition": .object(sourceDefinition), "builder_draft": .object(emptyDraft)
        ]
        vm.selectedRun = WorkflowRunModel(raw: initialRaw)
        #expect(vm.standaloneNodes.isEmpty)

        // when: the builder publishes a later draft containing an on-demand node.
        let laterDraft: [String: JSONValue] = ["on_demand_nodes": .array([.object([
                "id": .string("research"), "title": .string("Research"),
                "instructions": .string("Inspect the API."), "call_condition": .string("When uncertain.")
            ])])]
        var laterRaw = initialRaw
        laterRaw["builder_draft"] = .object(laterDraft)
        vm.selectedRun = WorkflowRunModel(raw: laterRaw)

        vm.selectStandalone("research")
        let before = vm.selectedRun?.raw
        vm.addOnDemandNode()
        vm.updateNode("research", key: "title", value: .string("Changed"))

        // then: the later draft is visible, but builder-run selection remains read-only.
        #expect(vm.standaloneNodes.map(\.id) == ["research"])
        #expect(vm.selectedOnDemandNode?.raw["title"] == .string("Research"))
        #expect(vm.selectedRun?.raw == before)
    }
}
