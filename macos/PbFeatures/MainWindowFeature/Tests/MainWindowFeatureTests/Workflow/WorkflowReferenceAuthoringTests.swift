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
        #expect(node.childSessionPolicy == "agent_decides")
        #expect(node.raw["child_session_policy"] == .string("agent_decides"))
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
            "instructions": .string("Review the result"), "optional": .bool(true), "max_attempts": .number(2),
            "child_session_policy": .string("agent_decides")]
        let definition: [String: JSONValue] = ["nodes": .array([.object(node)]), "connections": .array([])]
        // when
        let payload = try #require(WorkflowClipboard.payload(definition: definition, selection: ["call"]))
        let pasted = try #require(WorkflowClipboard.pasted(payload, into: definition))
        let copy = try #require(WorkflowJSON.nodes(pasted.definition).last)
        // then
        #expect(copy.id != "call")
        #expect(copy.workflowID == "stable")
        #expect(copy.orchestratorMode == "current")
        #expect(copy.childSessionPolicy == "agent_decides")
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

    @MainActor @Test func givenResumePreference_whenSwitchingCurrentAndChild_thenPreferenceSurvivesWhileSelectorIsInactive() throws {
        // given
        let vm = WorkflowTests().makeVM().sut
        vm.addNode("workflow")
        let id = try #require(vm.selectedNode).id
        vm.updateNode(id, key: "child_session_policy", value: .string("resume"))
        // when
        vm.updateNode(id, key: "orchestrator_mode", value: .string("current"))
        // then
        #expect(vm.selectedNode?.showsChildSessionPolicy == false)
        #expect(vm.selectedNode?.childSessionPolicy == "resume")
        #expect(WorkflowJSON.nodes(vm.effectiveDefinition).first { $0.id == id }?.childSessionPolicy == "resume")
        // when
        vm.updateNode(id, key: "orchestrator_mode", value: .string("child"))
        // then
        #expect(vm.selectedNode?.showsChildSessionPolicy == true)
        #expect(vm.selectedNode?.childSessionPolicy == "resume")
    }

    @Test func givenLegacyWorkflowNode_whenReadingPolicy_thenAgentDecidesIsDefault() {
        // given
        let node = WorkflowNodeModel(raw: ["type": .string("workflow")])
        // when / then
        #expect(node.childSessionPolicy == "agent_decides")
        #expect(node.showsChildSessionPolicy)
        #expect(!WorkflowNodeModel(raw: ["type": .string("agent")]).showsChildSessionPolicy)
    }

    @Test func givenExplicitFreshWorkflowNode_whenReadingPolicy_thenFreshRemainsSelected() {
        // given
        let node = WorkflowNodeModel(raw: ["type": .string("workflow"), "child_session_policy": .string("fresh")])
        // when / then
        #expect(node.childSessionPolicy == "fresh")
        #expect(node.showsChildSessionPolicy)
    }

    @Test func givenResumedInvocation_whenPresentingDetails_thenSourceAndRefusalRemainVisible() {
        // given
        let invocation: [String: JSONValue] = ["child_session_selection": .object([
            "requested_policy": .string("agent_decides"), "selected_mode": .string("resume"),
            "reason": .string("Continue planning"), "source_execution_id": .string("visit-one"),
            "source_child_workflow_run_id": .string("child-one"), "source_task_id": .string("task-one"),
            "source_session_id": .string("session-one")
        ]), "child_session_refusal": .string("Conversation is reserved")]
        // when
        let lines = WorkflowChildSessionDetails(invocation: invocation).lines
        // then
        #expect(lines == ["Child conversation requested: Agent decides", "Child conversation selected: Resume",
            "Reason: Continue planning", "Source invocation: visit-one", "Source workflow: child-one",
            "Source task: task-one", "Source conversation: session-one", "Child conversation refused: Conversation is reserved"])
        #expect(WorkflowChildSessionDetails(invocation: [:]).lines.isEmpty)
    }

}
