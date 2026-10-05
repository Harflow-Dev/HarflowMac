@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowReferenceAuthoringTests

struct WorkflowReferenceAuthoringTests {
    @MainActor
    @Test func givenNewWorkflow_whenAddingWorkflowNode_thenChildPermissionsCannotBeOverridden() throws {
        // given
        let vm = WorkflowTests().makeVM().sut
        // when
        vm.addNode("workflow")
        let node = try #require(vm.selectedNode)
        // then
        #expect(node.type == "workflow")
        #expect(node.orchestratorMode == "child")
        #expect(node.raw["max_attempts"] == .number(3))
        #expect(vm.definition["routing_mode"] == .string("explicit"))
        #expect(["agent", "freedom", "network", "session_mode", "role"].allSatisfy { node.raw[$0] == nil })
    }

    @Test func givenRenamedWorkflow_whenReadingReference_thenStableIdentityIsRetained() {
        // given
        let record = WorkflowRecord(raw: ["name": .string("Renamed"), "workflow_id": .string("stable")])
        let node = WorkflowNodeModel(raw: ["type": .string("workflow"), "workflow_ref": .object(["workflow_id": .string("stable")]), "optional": .bool(true)])
        // when / then
        #expect(record.id == "Renamed")
        #expect(record.workflowID == node.workflowID)
        #expect(node.isOptional)
        #expect(node.orchestratorMode == "child")
        #expect(WorkflowRole.palette.contains("workflow"))
        #expect(WorkflowRole.title("workflow") == "Run workflow")
    }

    @Test func givenWorkflowNode_whenCopyingAndPasting_thenReferenceAndModeRemainUnchanged() throws {
        // given
        let node: [String: JSONValue] = ["id": .string("call"), "type": .string("workflow"),
            "workflow_ref": .object(["workflow_id": .string("stable")]), "orchestrator_mode": .string("current"),
            "instructions": .string("Review the result"), "optional": .bool(true), "max_attempts": .number(2)]
        let definition: [String: JSONValue] = ["nodes": .array([.object(node)]), "connections": .array([])]
        // when
        let payload = try #require(WorkflowClipboard.payload(definition: definition, selection: ["call"]))
        let pasted = try #require(WorkflowClipboard.pasted(payload, into: definition))
        let copy = try #require(WorkflowJSON.nodes(pasted.definition).last)
        // then
        #expect(copy.id != "call")
        #expect(copy.workflowID == "stable")
        #expect(copy.orchestratorMode == "current")
        #expect(copy.instructions == "Review the result")
        #expect(copy.isOptional)
        #expect(copy.raw["max_attempts"] == .number(2))
        #expect(copy.raw["agent"] == nil)
    }

    @Test func givenBuilderProposalWithWorkflowNode_whenProjecting_thenProtocolDefinitionIsHidden() {
        // given
        let proposal = #"{"nodes":[{"id":"call","type":"workflow","workflow_ref":{"workflow_id":"stable"}}],"connections":[]}"#
        // when / then
        #expect(WorkflowBuilderPresentation.isDefinition(proposal))
        #expect(WorkflowBuilderPresentation.projectedText(proposal) == WorkflowBuilderPresentation.proposalSummary)
    }

    @Test func givenRetriedChildInvocation_whenOpeningCanvasNode_thenLatestAttemptIsSelected() {
        // given
        let run = WorkflowRunModel(raw: ["activations": .array([
            .object(["node_id": .string("call"), "invocation": .object(["child_workflow_run_id": .string("old"),
                "workflow_name": .string("Review"), "stage": .string("settled")])]),
            .object(["node_id": .string("other"), "invocation": .object(["child_workflow_run_id": .string("unrelated")])]),
            .object(["node_id": .string("call"), "invocation": .object(["child_workflow_run_id": .string("current"),
                "workflow_name": .string("Review"), "stage": .string("running")])])
        ])])
        // when / then
        #expect(run.latestChildRunID(for: "call") == "current")
        #expect(run.latestChildRunID(for: "missing") == nil)
        #expect(run.childRunLabel("current") == "Review · running")
    }

}
