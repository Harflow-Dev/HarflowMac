import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowActivityMessageTests

@MainActor
struct WorkflowActivityMessageTests {
    private let rootID = String(repeating: "a", count: 32)
    private let childID = String(repeating: "b", count: 32)

    @Test(arguments: [false, true])
    func givenSelectedNodeActivity_whenSending_thenExactCurrentTaskAndDeliveryModeAreRouted(_ now: Bool) async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let raw = run(taskID: "current-task")
        stub(harness.useCase, root: raw)
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        harness.sut.selectedNodeID = "work"
        await waitUntil { harness.sut.activityMessageTarget.taskID == "current-task" }
        // when
        #expect(harness.sut.submitActivityMessage("  exact caller prose\n", now: now))
        // then
        await verify(harness.useCase)
.command(.value("send"),
            options: .value(["--monitor", "--delivery=\(now ? "now" : "queue")", "--task-id=current-task"]),
            positionals: .value([rootID, "  exact caller prose\n"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenChildWorkflowActivity_whenSendingAndCancelling_thenOnlyChildOrchestratorRouteIsUsed() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let raw = run(taskID: nil, child: true)
        stub(harness.useCase, root: raw)
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        harness.sut.selectedNodeID = "work"
        await waitUntil { harness.sut.activityMessageTarget.runID == childID }
        // when
        #expect(harness.sut.submitActivityMessage("Ask the child orchestrator", now: false))
        await waitUntil { !harness.sut.isBusy }
        harness.sut.cancelActivityMessage("message-one")
        // then
        await verify(harness.useCase)
.command(.value("send"), options: .value(["--monitor", "--delivery=queue"]),
            positionals: .value([childID, "Ask the child orchestrator"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
        await verify(harness.useCase)
.command(.value("cancel-message"), options: .value(["--monitor"]),
            positionals: .value([childID, "message-one"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenUnsafeImmediateDelivery_whenEngineRefuses_thenQueuedMessageAndReasonRemainVisible() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        var raw = run(taskID: "current-task")
        raw["messages"] = .array([.object(message(taskID: "current-task"))])
        stub(harness.useCase, root: raw, refusesNow: true)
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        harness.sut.selectedNodeID = "work"
        await waitUntil { harness.sut.activityMessageTarget.taskID == "current-task" }
        // when
        #expect(harness.sut.submitActivityMessage("Keep this message", now: true))
        await waitUntil { harness.sut.errorText?.contains("cannot interrupt") == true }
        // then
        #expect(harness.sut.activityMessageItems.map(\.id) == ["message-one"])
        #expect(harness.sut.activityMessageItems.first?.canCancel == true)
        #expect(harness.sut.errorText == "Queued — This backend cannot interrupt safely.")
    }

    @Test func givenActivitySelectionChanged_whenSending_thenTheNewIssuedTaskIsCaptured() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let old = run(taskID: "old-task")
        let current = run(taskID: "new-task")
        stub(harness.useCase, root: current)
        harness.sut.selectedRun = WorkflowRunModel(raw: old)
        harness.sut.selectedNodeID = "work"
        await waitUntil { harness.sut.activityMessageTarget.taskID == "old-task" }
        // when
        harness.sut.selectedRun = WorkflowRunModel(raw: current)
        await waitUntil { harness.sut.activityMessageTarget.taskID == "new-task" }
        #expect(harness.sut.submitActivityMessage("Use the current target", now: false))
        // then
        await verify(harness.useCase)
.command(.value("send"),
            options: .value(["--monitor", "--delivery=queue", "--task-id=new-task"]),
            positionals: .value([rootID, "Use the current target"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenUnstartedNode_whenSending_thenSpecificDisabledReasonPreventsParentBroadcast() {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.selectedRun = WorkflowRunModel(raw: run(taskID: nil))
        harness.sut.runSidebar = .init()
        // when / then
        #expect(harness.sut.activityMessageTarget.unavailableReason?.contains("no issued task") == true)
        #expect(!harness.sut.submitActivityMessage("Do not broadcast", now: false))
        verify(harness.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).called(0)
    }

    @Test func givenChildQueueRead_whenLoaded_thenOnlyThatChildWorkflowMessagesArePresented() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let raw = run(taskID: nil, child: true)
        stub(harness.useCase, root: raw)
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        harness.sut.selectedNodeID = "work"
        await waitUntil { harness.sut.activityMessageTarget.runID == childID }
        // when
        await harness.sut.refreshActivityMessageState()
        // then
        #expect(harness.sut.activityMessageItems.map(\.id) == ["message-one"])
        #expect(harness.sut.activityMessageItems.first?.text == "Keep this message")
    }

    @Test func givenOrchestratorCard_whenSelected_thenItsRightHandActivityOwnsTheMessageTarget() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        var raw = run(taskID: "orchestrator-task")
        var activation = WorkflowJSON.objects(raw["activations"])[0]
        activation["role"] = .string("orchestrator")
        raw["activations"] = .array([.object(activation)])
        stub(harness.useCase, root: raw)
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        // when
        harness.sut.selectStandalone(WorkflowStandalone.orchestratorID)
        await waitUntil { harness.sut.runSidebar.node?["id"]?.stringValue == WorkflowStandalone.orchestratorID }
        // then
        #expect(harness.sut.selectedNodeID == WorkflowStandalone.orchestratorID)
        #expect(harness.sut.activityMessageTarget.taskID == "orchestrator-task")
        #expect(harness.sut.activityMessageTarget.runID == rootID)
    }

    @Test func givenUnsupportedChildQueueRead_whenRefreshed_thenEngineCompatibilityReasonRemainsVisible() async {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let raw = run(taskID: nil, child: true)
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-status", detail: "old engine")
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willThrow(error)
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        harness.sut.selectedNodeID = "work"
        await waitUntil { harness.sut.activityMessageTarget.runID == childID }
        // when
        await harness.sut.refreshActivityMessageState()
        // then
        #expect(harness.sut.activityMessageReadError == "Queued messages could not be refreshed: " + error.message)
    }

    private func stub(_ useCase: MockWorkflowUseCase, root: [String: JSONValue], refusesNow: Bool = false) {
        let expectedChildID = childID
        let child: [String: JSONValue] = ["workflow_run_id": .string(childID), "status": .string("running"),
            "messages": .array([.object(message(taskID: nil))])]
        given(useCase)
.command(.any, options: .any, positionals: .any, runtime: .any)
            .willProduce { command, _, positionals, _ in
                if command == "status" { return positionals.first == expectedChildID ? child : root }
                if command == "send" {
                    var result: [String: JSONValue] = ["status": .string("queued"), "message_id": .string("message-one")]
                    if refusesNow { result["refusal"] = .object(["message": .string("This backend cannot interrupt safely.")]) }
                    return result
                }
                return [:]
            }
    }

    private func message(taskID: String?) -> [String: JSONValue] {
        var target: [String: JSONValue] = ["kind": .string("workflow")]
        if let taskID { target = ["kind": .string("task"), "task_id": .string(taskID)] }
        return ["id": .string("message-one"), "status": .string("queued"), "text": .string("Keep this message"), "target": .object(target)]
    }

    private func run(taskID: String?, child: Bool = false) -> [String: JSONValue] {
        var activation: [String: JSONValue] = ["id": .string("issued-execution"), "node_id": .string("work"),
            "role": .string("node"), "status": .string("running"), "tasks": .array(taskID.map { [.object([
                "task_id": .string($0), "status": .string("running")])] } ?? [])]
        if child { activation["invocation"] = .object(["child_workflow_run_id": .string(childID)]) }
        return ["workflow_run_id": .string(rootID), "status": .string("running"), "kind": .string("workflow"),
            "definition": .object(["nodes": .array([.object(["id": .string("work"), "type": .string(child ? "workflow" : "agent")])])]),
            "activations": .array([.object(activation)])]
    }
}
