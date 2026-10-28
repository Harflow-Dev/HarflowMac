@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowRunSidebarPresentationTests

struct WorkflowRunSidebarPresentationTests {
    @Test func givenAgentWithMultipleAttempts_whenBuilding_thenRequestedAttemptWinsAndEveryTaskRemainsDiscoverable() {
        let run = makeRun(nodes: [["id": .string("agent"), "type": .string("agent"), "title": .string("Draft")]], activations: [
            activation(id: "first", nodeID: "agent", status: "completed", tasks: [task("headless-1"), task("native-1", kind: "native_subagent")]),
            activation(id: "live", nodeID: "agent", status: "running", tasks: [task("headless-2")])
        ])

        let presentation = WorkflowRunSidebarPresentation.build(run: run, nodeID: "agent", attemptID: "first")

        #expect(presentation.title == "Draft")
        #expect(presentation.attempts.map(\.id) == ["first", "live"])
        #expect(presentation.activationID == "first")
        #expect(presentation.taskIDs == ["headless-1", "native-1"])
        #expect(presentation.allTaskIDs == ["headless-1", "native-1", "headless-2"])
        #expect(presentation.latestTaskIDs == ["headless-2"])
        #expect(presentation.titles["headless-1"] == "Draft · 1")
        #expect(presentation.titles["native-1"] == "Draft · 1 · Fallback 1")
    }

    @Test func givenRunningAttemptWithoutExplicitSelection_whenBuilding_thenRunningAttemptIsSelected() {
        let run = makeRun(nodes: [["id": .string("agent"), "type": .string("agent")]], activations: [
            activation(id: "old", nodeID: "agent", status: "completed"),
            activation(id: "live", nodeID: "agent", status: "launch_requested")
        ])

        #expect(WorkflowRunSidebarPresentation.build(run: run, nodeID: "agent", attemptID: nil).activationID == "live")
    }

    @Test func givenInvalidAttemptSelection_whenBuilding_thenLatestAttemptIsUsed() {
        let run = makeRun(nodes: [["id": .string("agent"), "type": .string("agent")]], activations: [
            activation(id: "one", nodeID: "agent", status: "completed"),
            activation(id: "two", nodeID: "agent", status: "completed")
        ])

        #expect(WorkflowRunSidebarPresentation.build(run: run, nodeID: "agent", attemptID: "stale").activationID == "two")
    }

    @Test func givenStructuralOrMissingSelection_whenBuilding_thenDefaultPresentationIsReturned() {
        let run = makeRun(nodes: [
            ["id": .string("start"), "type": .string("start")],
            ["id": .string("agent"), "type": .string("agent")]
        ], activations: [])

        let structural = WorkflowRunSidebarPresentation.build(run: run, nodeID: "start", attemptID: nil)
        let missing = WorkflowRunSidebarPresentation.build(run: run, nodeID: "gone", attemptID: nil)

        #expect(structural.isDefault)
        #expect(structural.selectedNodeExists)
        #expect(missing.isDefault)
        #expect(!missing.selectedNodeExists)
    }

    @Test func givenOnDemandNode_whenBuilding_thenCallsAreRetainedWithoutTaskActivity() {
        var run = makeRun(nodes: [], activations: [])
        run["on_demand_nodes"] = .array([.object([
            "node_id": .string("standalone"), "title": .string("Run checks")
        ])])
        run["on_demand_calls"] = .array([.object([
            "node_id": .string("standalone"), "status": .string("completed")
        ])])

        let presentation = WorkflowRunSidebarPresentation.build(run: run, nodeID: "standalone", attemptID: nil)

        #expect(presentation.isOnDemand)
        #expect(presentation.title == "Run checks")
        #expect(presentation.calls.count == 1)
        #expect(presentation.taskIDs.isEmpty)
    }

    @Test func givenNestedWorkflowInvocation_whenBuilding_thenChildRunIdentityIsExposed() {
        let run = makeRun(nodes: [["id": .string("child"), "type": .string("workflow"), "title": .string("Review")]], activations: [
            activation(id: "child-attempt", nodeID: "child", status: "completed",
                       extra: ["invocation": .object(["child_workflow_run_id": .string("nested-run")])])
        ])

        let presentation = WorkflowRunSidebarPresentation.build(run: run, nodeID: "child", attemptID: nil)

        #expect(presentation.childRunID == "nested-run")
        #expect(presentation.title == "Review")
    }

    private func makeRun(nodes: [[String: JSONValue]], activations: [[String: JSONValue]]) -> [String: JSONValue] {
        [
            "definition": .object(["nodes": .array(nodes.map(JSONValue.object))]),
            "activations": .array(activations.map(JSONValue.object))
        ]
    }

    private func task(_ id: String, kind: String = "headless") -> [String: JSONValue] {
        ["task_id": .string(id), "execution_kind": .string(kind)]
    }

    private func activation(id: String, nodeID: String, status: String,
                            tasks: [[String: JSONValue]] = [],
                            extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "id": .string(id), "role": .string("node"), "node_id": .string(nodeID),
            "status": .string(status), "tasks": .array(tasks.map(JSONValue.object))
        ]
        result.merge(extra) { _, new in new }
        return result
    }
}
