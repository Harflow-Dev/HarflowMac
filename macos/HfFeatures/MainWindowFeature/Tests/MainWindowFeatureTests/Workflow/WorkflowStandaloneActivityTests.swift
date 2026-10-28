@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowStandaloneActivityTests

struct WorkflowStandaloneActivityTests {
    @Test(arguments: ["reserved", "not_started", "uncertain", "completed", "failed", "cancelled"])
    func givenUnconfirmedOrSettledDecision_whenProjectingCard_thenItIsIdle(status: String) {
        // given / when / then
        let raw = run([activation("decision", role: "orchestrator", taskStatus: status)])
        #expect(WorkflowStandaloneActivity.status(nodeID: WorkflowStandalone.orchestratorID, run: raw) == "pending")
    }

    @Test func givenRunningActivationWithoutTasks_whenDeciding_thenNoRunningGlowIsInvented() {
        // given
        var raw = run([["id": .string("empty"), "role": .string("orchestrator"), "status": .string("running"), "tasks": .array([])]])
        raw["on_demand_state"] = .object(["kind": .string("deciding")])
        // when / then
        #expect(WorkflowStandaloneActivity.status(nodeID: WorkflowStandalone.orchestratorID, run: raw) == "pending")
    }

    @Test func givenRunningDecision_whenItSettles_thenGlowStopsAndLatestActivityRemainsSelected() {
        // given
        var raw = run([activation("decision", role: "orchestrator", taskStatus: "running")])
        #expect(WorkflowStandaloneActivity.status(nodeID: WorkflowStandalone.orchestratorID, run: raw) == "running")
        // when
        raw["activations"] = .array([.object(activation("decision", role: "orchestrator", taskStatus: "completed"))])
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        // then
        #expect(WorkflowStandaloneActivity.status(nodeID: WorkflowStandalone.orchestratorID, run: raw) == "pending")
        #expect(!projection.isDefault)
        #expect(projection.title == "Orchestrator")
        #expect(projection.activationID == "decision")
        #expect(projection.taskIDs == ["task-decision"])
    }

    @Test func givenMultipleDecisions_whenNewPollingArrives_thenExplicitHistoryWinsAndWorkersStayUnchanged() {
        // given
        let old = activation("old", role: "orchestrator", taskStatus: "completed")
        let active = activation("active", role: "orchestrator", taskStatus: "running")
        let newer = activation("newer", role: "orchestrator", taskStatus: "reserved")
        let worker = activation("worker", role: "node", taskStatus: "running")
        let raw = run([old, active, newer, worker])
        // when
        let selected = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: "old")
        let automatic = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        // then
        #expect(selected.attempts.map(\.id) == ["old", "active", "newer"])
        #expect(selected.activationID == "old")
        #expect(automatic.activationID == "active")
        #expect(selected.allTaskIDs == ["task-worker"])
        #expect(selected.latestTaskIDs == ["task-worker"])
        #expect(!WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: WorkflowJSON.objects(raw["activations"])))
        #expect(WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: [old, active]))
    }

    @Test(arguments: ["headless", "native_subagent"])
    func givenConsultantCall_whenItsExactExecutionExists_thenActivityUsesEveryTaskOfThatExecution(kind: String) {
        // given
        var exact = activation("exact", role: "node", taskStatus: "running")
        exact["execution_kind"] = .string(kind)
        exact["tasks"] = .array([.object(["task_id": .string("consultant-task"), "status": .string("running"), "execution_kind": .string(kind)])])
        var raw = run([activation("unrelated", role: "node", taskStatus: "running"), exact])
        raw["on_demand_nodes"] = .array([.object(["node_id": .string("consultant"), "title": .string("Consultant")])])
        raw["on_demand_calls"] = .array([.object(["id": .string("call"), "node_id": .string("consultant"), "execution_id": .string("exact"),
                                                 "reason": .string("Verify evidence")])])
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        // then
        #expect(projection.isOnDemand)
        #expect(projection.activationID == "exact")
        #expect(projection.calls.first?["reason"]?.stringValue == "Verify evidence")
        #expect(projection.taskIDs == ["consultant-task"])
        #expect(WorkflowExecutionPresentation(raw: exact).isSubagent == (kind == "native_subagent"))
        #expect(WorkflowStandaloneActivity.status(nodeID: "consultant", run: raw) == "running")
    }

    @Test func givenMissingLatestConsultantExecution_whenOlderHistoryExists_thenNoOtherActivityIsSubstituted() {
        // given
        var raw = run([activation("old", role: "node", taskStatus: "completed")])
        raw["on_demand_nodes"] = .array([.object(["node_id": .string("consultant"), "active_call_id": .string("missing-call")])])
        raw["on_demand_calls"] = .array([
            .object(["id": .string("old-call"), "node_id": .string("consultant"), "execution_id": .string("old")]),
            .object(["id": .string("missing-call"), "node_id": .string("consultant"), "execution_id": .string("missing"), "status": .string("running")])
        ])
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        // then
        #expect(projection.calls.count == 2)
        #expect(projection.attempts.count == 2)
        #expect(projection.activationID == "unavailable:missing-call")
        #expect(projection.taskIDs.isEmpty)
        #expect(WorkflowStandaloneActivity.status(nodeID: "consultant", run: raw) == "pending")
    }

    @Test func givenDefaultInspector_whenTaskTransitions_thenPrecomputedStandaloneMapChangesWithoutWorkerInventoryChanges() {
        // given
        let worker = activation("worker", role: "node", taskStatus: "running")
        let running = run([worker, activation("decision", role: "orchestrator", taskStatus: "running")])
        let idle = run([worker, activation("decision", role: "orchestrator", taskStatus: "completed")])
        // when
        let activeProjection = WorkflowRunSidebarPresentation.build(run: running, nodeID: nil, attemptID: nil)
        let idleProjection = WorkflowRunSidebarPresentation.build(run: idle, nodeID: nil, attemptID: nil)
        // then
        #expect(activeProjection.isDefault && idleProjection.isDefault)
        #expect(activeProjection.standaloneStatuses[WorkflowStandalone.orchestratorID] == "running")
        #expect(idleProjection.standaloneStatuses[WorkflowStandalone.orchestratorID] == "pending")
        #expect(activeProjection != idleProjection)
        #expect(idleProjection == WorkflowRunSidebarPresentation.build(run: idle, nodeID: nil, attemptID: nil))
        #expect(activeProjection.allTaskIDs == idleProjection.allTaskIDs)
        #expect(activeProjection.latestTaskIDs == idleProjection.latestTaskIDs)
        var builder = running
        builder["kind"] = .string("builder")
        #expect(WorkflowRunSidebarPresentation.build(run: builder, nodeID: nil, attemptID: nil).standaloneStatuses.isEmpty)
    }

    @Test func givenNoncontiguousConsultantCallNumbers_whenBuildingPicker_thenPersistedNumbersAreRetained() {
        // given
        var raw = run([activation("seventh", role: "node", taskStatus: "completed"),
                       activation("ninth", role: "node", taskStatus: "completed")])
        raw["on_demand_nodes"] = .array([.object(["node_id": .string("consultant")])])
        raw["on_demand_calls"] = .array([
            .object(["id": .string("call-seven"), "node_id": .string("consultant"), "execution_id": .string("seventh"), "call_number": .number(7)]),
            .object(["id": .string("call-nine"), "node_id": .string("consultant"), "execution_id": .string("ninth"), "call_number": .number(9)]),
            .object(["id": .string("missing"), "node_id": .string("consultant"), "call_number": .number(12)])
        ])
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        // then
        #expect(projection.attempts.map(\.title) == ["Call 7 · running", "Call 9 · running", "Call 12 · unknown"])
    }

    private func activation(_ id: String, role: String, taskStatus: String) -> [String: JSONValue] {
        ["id": .string(id), "node_id": .string("work"), "role": .string(role), "status": .string("running"),
         "tasks": .array([.object(["task_id": .string("task-" + id), "status": .string(taskStatus)])])]
    }

    private func run(_ activations: [[String: JSONValue]]) -> [String: JSONValue] {
        ["definition": .object(["nodes": .array([.object(["id": .string("work"), "type": .string("agent")])])]),
         "activations": .array(activations.map(JSONValue.object))]
    }
}
