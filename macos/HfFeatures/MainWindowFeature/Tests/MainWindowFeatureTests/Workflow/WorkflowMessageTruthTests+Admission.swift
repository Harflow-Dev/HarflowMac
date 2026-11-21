import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

extension WorkflowMessageTruthTests {
    func nestedRun(status: String, orchestratorTaskID: String?, workerTaskID: String? = nil) throws -> [String: JSONValue] {
        var raw = run(status: status, taskID: orchestratorTaskID)
        raw["workflow_run_id"] = .string(childID)
        raw["parent_workflow_run_id"] = .string(rootID)
        var orchestrator = try #require(WorkflowJSON.objects(raw["activations"]).first)
        orchestrator["id"] = .string("nested-orchestrator-execution")
        orchestrator["node_id"] = .string(WorkflowStandalone.orchestratorID)
        orchestrator["role"] = .string("orchestrator")
        var activations: [JSONValue] = [.object(orchestrator)]
        if let workerTaskID {
            activations.append(.object([
                "id": .string("nested-worker-execution"), "node_id": .string("work"), "role": .string("node"),
                "status": .string("running"),
                "tasks": .array([.object(["task_id": .string(workerTaskID), "status": .string("running")])])
            ]))
        }
        raw["activations"] = .array(activations)
        return raw
    }

    private func expectLockedFallback(_ model: MessageBoxModel) {
        #expect(model.isLocked)
        #expect(!model.canSend)
        #expect(model.placeholder == MessageBoxDisabledReason.runCancelling.text)
        #expect(!model.showsSendNow)
    }

    @Test func givenANestedOrchestrator_whenHeadlessComposerSends_thenCurrentPhaseAndSelectionAreEnforced() async throws {
        let headless = makeHarness()
        let taskID = "nested-orchestrator-task"
        let raw = try nestedRun(status: "running", orchestratorTaskID: taskID)
        headless.status.value = raw
        given(headless.parallel.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        headless.vm.selectedRun = WorkflowRunModel(raw: raw)
        headless.vm.selectStandalone(WorkflowStandalone.orchestratorID)
        headless.vm.didAppear()
        defer { headless.vm.didDisappear() }
        await waitUntil {
            headless.vm.runSidebar.header.kind == .orchestrator
                && headless.vm.activityMessageTarget.runID == childID
                && headless.vm.activityMessageTarget.taskID == taskID
        }

        let task = ParallelVMTests().task(id: taskID)
        headless.parallel.tasksBox.value[taskID] = task
        headless.parallel.itemsBox.value[taskID] = [PreviewFixtures.textItem("Nested orchestrator activity")]
        let inspector = try #require(headless.vm.selectedActivity)
        inspector.didAppear()
        headless.parallel.tasksSubject.send([task])
        await waitUntil { inspector.columns.count == 1 && inspector.isPresentationSettled }
        let runningHeadlessSend = try #require(inspector.columns.first?.onSubmitMessage)
        #expect(inspector.columns.first?.messageLock == nil)
        #expect(runningHeadlessSend("Headless nested message", false))
        await verify(headless.parallel.useCase)
.sendMessage(.value(taskID), text: .value("Headless nested message"), now: .value(false))
            .calledEventually(1, before: .seconds(5))

        // A -> none -> A changes the route generation: the exact old callback is stale, and the fresh one still sends.
        let writesBeforeReselection = inspector.presentationWriteCount
        headless.vm.selectNodes([], primary: nil)
        await headless.vm.sidebarTask?.value
        headless.vm.selectStandalone(WorkflowStandalone.orchestratorID)
        await headless.vm.sidebarTask?.value
        inspector.didAppear()
        headless.parallel.tasksSubject.send([task])
        await waitUntil {
            headless.vm.selectedActivity === inspector && inspector.presentationWriteCount > writesBeforeReselection
                && inspector.isPresentationSettled && inspector.columns.first?.messageLock == nil
                && inspector.columns.first?.messageAdmission == inspector.workflowMessageAdmission
        }
        let reselectedSend = try #require(inspector.columns.first?.onSubmitMessage)
        #expect(!runningHeadlessSend("stale after reselect", false))
        #expect(reselectedSend("fresh after reselect", false))
        await verify(headless.parallel.useCase)
.sendMessage(.value(taskID), text: .value("fresh after reselect"), now: .value(false))
            .calledEventually(1, before: .seconds(5))
        verify(headless.parallel.useCase).sendMessage(.any, text: .any, now: .any).called(2)
    }

    @Test func givenNestedRunCancelling_whenOrchestratorAndWorkerAreSelected_thenOnlyWorkerSends() async throws {
        let harness = makeHarness()
        let taskID = "nested-orchestrator-task"
        let workerTaskID = "nested-worker-task"
        let raw = try nestedRun(status: "cancelling", orchestratorTaskID: taskID, workerTaskID: workerTaskID)
        harness.status.value = raw
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectStandalone(WorkflowStandalone.orchestratorID)
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.runSidebar.header.kind == .orchestrator && harness.vm.activityMessagePhaseLock == .runCancelling }

        let task = ParallelVMTests().task(id: taskID)
        harness.parallel.tasksBox.value[taskID] = task
        let orchestrator = try #require(harness.vm.selectedActivity)
        orchestrator.didAppear()
        harness.parallel.tasksSubject.send([task])
        await waitUntil { orchestrator.columns.count == 1 && orchestrator.isPresentationSettled }
        let blocked = try #require(orchestrator.columns.first?.onSubmitMessage)
        #expect(orchestrator.columns.first?.messageLock == .runCancelling)
        #expect(!blocked("orchestrator blocked", false))

        let workerTask = ParallelVMTests().task(id: workerTaskID)
        harness.parallel.tasksBox.value[workerTaskID] = workerTask
        harness.parallel.itemsBox.value[workerTaskID] = [PreviewFixtures.textItem("Nested worker")]
        harness.vm.selectedNodeID = "work"
        await harness.vm.sidebarTask?.value
        let worker = try #require(harness.vm.selectedActivity)
        worker.didAppear()
        harness.parallel.tasksSubject.send([task, workerTask])
        await waitUntil { worker.columns.count == 1 && worker.isPresentationSettled }
        let allowed = try #require(worker.columns.first?.onSubmitMessage)
        #expect(worker.columns.first?.messageLock == nil)
        given(harness.parallel.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        #expect(allowed("worker stays active", false))
        await verify(harness.parallel.useCase)
.sendMessage(.value(workerTaskID), text: .value("worker stays active"),
            now: .value(false))
.calledEventually(1, before: .seconds(5))

        var cancelled = raw
        cancelled["status"] = .string("cancelled")
        harness.status.value = cancelled
        harness.vm.selectedRun = WorkflowRunModel(raw: cancelled)
        harness.vm.selectStandalone(WorkflowStandalone.orchestratorID)
        await harness.vm.sidebarTask?.value
        orchestrator.didAppear()
        harness.parallel.tasksSubject.send([task])
        await waitUntil {
            harness.vm.activityMessagePhaseLock == .runCancelled
                && harness.vm.selectedActivity === orchestrator
                && orchestrator.columns.first?.messageLock == .runCancelled && orchestrator.isPresentationSettled
                && orchestrator.columns.first?.messageAdmission == orchestrator.workflowMessageAdmission
        }
        #expect(harness.vm.selectedActivity?.columns.first?.messageLock == .runCancelled)
        #expect(harness.vm.selectedActivity?.columns.first?.onSubmitMessage?("cancelled", false) == false)
    }

    @Test func givenANestedOrchestratorFallback_whenItsTaskIsRemovedUnderLock_thenCurrentAdmissionRefuses() async throws {
        let fallback = makeHarness()
        let taskID = "nested-orchestrator-task"
        let raw = try nestedRun(status: "running", orchestratorTaskID: taskID)
        given(fallback.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).willReturn([
            "status": .string("queued"), "message_id": .string("fallback-message")
        ])
        given(fallback.useCase)
.command(.value("status"), options: .any, positionals: .value([childID]), runtime: .any)
            .willReturn(raw)
        fallback.status.value = raw
        fallback.vm.selectedRun = WorkflowRunModel(raw: raw)
        fallback.vm.selectStandalone(WorkflowStandalone.orchestratorID)
        fallback.vm.didAppear()
        defer { fallback.vm.didDisappear() }
        await waitUntil {
            fallback.vm.runSidebar.header.kind == .orchestrator
                && fallback.vm.activityMessageTarget.runID == childID
                && fallback.vm.activityMessageTarget.taskID == taskID
        }
        #expect(fallback.vm.selectedActivity?.columns.isEmpty != false,
                "The fallback path has no mounted headless task column")
        let fallbackSend = fallback.vm.activityMessageSubmitter(now: false)
        #expect(fallbackSend("Fallback nested message"))
        await verify(fallback.useCase)
.command(.value("send"),
            options: .value(["--monitor", "--delivery=queue", "--task-id=\(taskID)"]),
            positionals: .value([childID, "Fallback nested message"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))

        var fallbackCancelling = raw
        fallbackCancelling["status"] = .string("cancelling")
        fallback.status.value = fallbackCancelling
        fallback.vm.selectedRun = WorkflowRunModel(raw: fallbackCancelling)
        await fallback.vm.sidebarTask?.value
        await waitUntil {
            fallback.vm.sidebarTask == nil && !fallback.vm.isBusy
                && fallback.vm.runSidebar.activationID == "nested-orchestrator-execution"
                && fallback.vm.activityMessagePhaseLock == .runCancelling
        }
        #expect(fallback.vm.activityMessageTarget.unavailableReason == nil)
        let cancellingFallbackSend = fallback.vm.activityMessageSubmitter(now: false)
        #expect(!cancellingFallbackSend("blocked by current cancelling phase"))
        verify(fallback.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).called(1)

        // Remove the target only after proving phase admission refuses it independently.
        var fallbackActivation = try #require(WorkflowJSON.objects(fallbackCancelling["activations"]).first)
        fallbackActivation["tasks"] = .array([])
        fallbackCancelling["activations"] = .array([.object(fallbackActivation)])
        fallback.status.value = fallbackCancelling
        fallback.vm.selectedRun = WorkflowRunModel(raw: fallbackCancelling)
        await fallback.vm.sidebarTask?.value
        await waitUntil {
            fallback.vm.sidebarTask == nil && fallback.vm.runSidebar.taskIDs.isEmpty
                && fallback.vm.activityMessagePhaseLock == .runCancelling
        }
        #expect(fallback.vm.activityMessageTarget.unavailableReason != nil,
                "The cancelling fallback fixture has no issued orchestrator task")
        let lockedFallbackSend = fallback.vm.activityMessageSubmitter(now: false)
        #expect(!lockedFallbackSend("no task while cancelling"))
        let lockedFallback = WorkflowActivityMessageComposer<WorkflowVM>.boxModel(
            target: fallback.vm.activityMessageTarget, unsupported: false, isBusy: false,
            phaseLock: fallback.vm.activityMessagePhaseLock)
        expectLockedFallback(lockedFallback)
    }

    @Test func givenAComposerScope_whenRawPhaseIsMapped_thenOnlyItsExactRolePhasesLock() {
        let lane = WorkflowMessageScope(runID: rootID, nodeID: nil, activationID: nil, role: .lanes)
        let nestedOrchestrator = WorkflowMessageScope(runID: childID, nodeID: "orchestrator", activationID: "call-1",
                                                       role: .orchestrator)
        let node = WorkflowMessageScope(runID: rootID, nodeID: "worker", activationID: "attempt-1", role: .node)
        let builderLane = WorkflowMessageScope(runID: rootID, nodeID: nil, activationID: nil, role: .builderLanes)
        let builderNode = WorkflowMessageScope(runID: rootID, nodeID: "builder", activationID: "attempt-1", role: .builderNode)

        for scope in [lane, nestedOrchestrator] {
            #expect(scope.phaseLock("completed") == .runCompleted)
            #expect(scope.phaseLock("cancelling") == .runCancelling)
            #expect(scope.phaseLock("cancelled") == .runCancelled)
        }
        #expect(node.phaseLock("completed") == nil)
        #expect(node.phaseLock("cancelling") == nil)
        #expect(node.phaseLock("cancelled") == .runCancelled)
        #expect(builderLane.phaseLock("completed") == nil)
        #expect(builderLane.phaseLock("cancelling") == nil)
        #expect(builderLane.phaseLock("cancelled") == .runCancelled)
        #expect(builderNode.phaseLock("completed") == nil)
        #expect(builderNode.phaseLock("cancelling") == nil)
        #expect(builderNode.phaseLock("cancelled") == nil)
        for phase in ["failed", "paused", "settling", "CANCELLED"] {
            #expect(lane.phaseLock(phase) == nil, "Unknown raw phase \(phase) must not infer a lock")
            #expect(builderNode.phaseLock(phase) == nil)
        }
    }

    @Test func givenAParentGraphAndChildTarget_whenParentPhaseChanges_thenAdmissionUsesTheParentPhase() async throws {
        // given
        let harness = makeHarness()
        var raw = run(status: "running")
        var activation = try #require(WorkflowJSON.objects(raw["activations"]).first)
        activation["invocation"] = .object(["child_workflow_run_id": .string(childID)])
        activation["node_result"] = .object(["result": .object(["child_outcome": .object(["child_status": .string("completed")])])])
        raw["activations"] = .array([.object(activation)])
        harness.status.value = raw
        var terminalChild: [String: JSONValue] = ["workflow_run_id": .string(childID), "status": .string("completed")]
        terminalChild["parent_workflow_run_id"] = .string(rootID)
        given(harness.useCase)
.command(.value("status"), options: .any, positionals: .value([rootID]), runtime: .any)
            .willProduce { _, _, _, _ in harness.status.value }
        given(harness.useCase)
.command(.value("status"), options: .any, positionals: .value([childID]), runtime: .any)
            .willReturn(terminalChild)
        given(harness.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).willReturn([
            "status": .string("queued"), "message_id": .string("child-message")
        ])
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectedNodeID = "work"
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.activityMessageTarget.runID == childID }

        // A terminal child remains messageable while its containing parent graph is active.
        #expect(harness.vm.activityMessagePhaseLock == nil)
        #expect(harness.vm.submitActivityMessage("message terminal child", now: false))
        await verify(harness.useCase)
.command(.value("send"),
            options: .value(["--monitor", "--delivery=queue"]),
            positionals: .value([childID, "message terminal child"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))

        // when — the target remains the child run while the parent graph changes phase.
        var cancelled = raw
        cancelled["status"] = .string("cancelled")
        harness.status.value = cancelled
        harness.vm.selectedRun = WorkflowRunModel(raw: cancelled)
        await waitUntil { harness.vm.activityMessagePhaseLock == .runCancelled }

        // then
        #expect(harness.vm.activityMessageTarget.runID == childID)
        #expect(harness.vm.activityMessageTarget.taskID == nil)
        #expect(harness.vm.activityMessagePhaseLock == .runCancelled)
        #expect(!harness.vm.submitActivityMessage("blocked by parent graph", now: false))
    }

    @Test func givenAWorkflowLaneRefusedForMissingMessaging_whenRuntimeIsReplaced_thenOnlyFreshAdmissionSends() async throws {
        // given — an unknown support probe still admits a real lane send under the current runtime.
        let harness = makeHarness(supported: nil)
        let raw = run(status: "running")
        harness.status.value = raw
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.setRunGraphVisible(false)
        let task = ParallelVMTests().task(id: "current-task")
        harness.parallel.tasksBox.value[task.taskID] = task
        harness.parallel.itemsBox.value[task.taskID] = [PreviewFixtures.textItem("Current workflow lane")]
        let shouldRefuse = ParallelVMTests.Box(true)
        let refusal = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: "Missing capability messaging.v1")
        given(harness.parallel.useCase).sendMessage(.any, text: .any, now: .any).willProduce { _, _, _ in
            guard !shouldRefuse.value else { throw refusal }
            return [:]
        }
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        harness.parallel.tasksSubject.send([task])
        await waitUntil { harness.vm.parallel.columns.count == 1 && harness.vm.parallel.isPresentationSettled }
        let firstSubmit = try #require(harness.vm.parallel.columns.first?.onSubmitMessage)

        // when — the current lane refusal establishes unsupported messaging for the shared owner.
        #expect(firstSubmit("queue this", false))
        await waitUntil { harness.vm.messagingUnsupported && !harness.vm.parallel.columns.first!.isBusy }

        // then — unsupported locks the workflow lane and blocks its already-rendered callback.
        #expect(harness.vm.parallel.columns.first?.messageLock == .messagingUnsupported)
        #expect(!firstSubmit("must stay local", false))

        // Standalone groups are unscoped and retain their independent send behavior during the refusal.
        let standalone = ParallelVMTests().makeSUT()
        let standaloneTask = ParallelVMTests().task(id: "standalone-task")
        standalone.tasksBox.value[standaloneTask.taskID] = standaloneTask
        given(standalone.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        standalone.sut.didAppear()
        defer { standalone.sut.didDisappear() }
        standalone.tasksSubject.send([standaloneTask])
        await waitUntil { standalone.sut.columns.count == 1 && standalone.sut.isPresentationSettled }
        #expect(standalone.sut.columns.first?.messageLock == nil)
        #expect(standalone.sut.columns.first?.onSubmitMessage?("standalone remains active", false) == true)
        await verify(standalone.useCase)
            .sendMessage(.value("standalone-task"), text: .value("standalone remains active"), now: .value(false))
            .calledEventually(1, before: .seconds(5))

        // when — a fresh invocation context proves the replacement runtime supports queued messaging.
        harness.context.value = makeContext()
        harness.supported.value = true
        harness.vm.prepareMessagingSupport()
        await waitUntil { harness.vm.messagingSupported == true && !harness.vm.parallel.columns.first!.isBusy }
        shouldRefuse.value = false

        // then — only the newly published callback carries the replacement runtime admission.
        #expect(!firstSubmit("stale runtime", false))
        let freshSubmit = try #require(harness.vm.parallel.columns.first?.onSubmitMessage)
        #expect(freshSubmit("replacement runtime", false))
        await verify(harness.parallel.useCase)
            .sendMessage(.value("current-task"), text: .value("replacement runtime"), now: .value(false))
            .calledEventually(1, before: .seconds(5))
        verify(harness.parallel.useCase).sendMessage(.any, text: .any, now: .any).called(2)
    }

    @Test func givenCachedGraphInspector_whenAWorkerPhaseChanges_thenReselectionAndStaleCallbacksUseCurrentPhase() async throws {
        // given — the same worker activation remains cached through selection changes.
        let harness = makeHarness()
        let raw = run(status: "completed")
        harness.status.value = raw
        given(harness.parallel.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        harness.vm.selectedRun = WorkflowRunModel(raw: raw)
        harness.vm.selectedNodeID = "work"
        harness.vm.didAppear()
        defer { harness.vm.didDisappear() }
        await waitUntil { harness.vm.selectedActivity != nil }
        let inspector = try #require(harness.vm.selectedActivity)
        let task = ParallelVMTests().task(id: "current-task")
        harness.parallel.tasksBox.value[task.taskID] = task
        harness.parallel.itemsBox.value[task.taskID] = [PreviewFixtures.textItem("Worker transcript")]
        harness.parallel.availabilityBox.value[task.taskID] = .available
        harness.parallel.tasksSubject.send([task])
        await waitUntil { inspector.columns.count == 1 && inspector.isPresentationSettled }
        let completedSend = try #require(inspector.columns.first?.onSubmitMessage)
        #expect(inspector.columns.first?.messageLock == nil, "completed worker nodes remain sendable")

        // when — deselecting and reselecting while the containing run is cancelling reuses the scoped inspector.
        harness.vm.selectNodes([], primary: nil)
        await harness.vm.sidebarTask?.value
        let cancelling = run(status: "cancelling")
        harness.status.value = cancelling
        harness.vm.selectedRun = WorkflowRunModel(raw: cancelling)
        harness.vm.selectedNodeID = "work"
        await harness.vm.sidebarTask?.value
        inspector.didAppear()
        harness.parallel.tasksSubject.send([task])
        await waitUntil {
            harness.vm.selectedActivity === inspector && inspector.columns.count == 1 && inspector.isPresentationSettled
                && inspector.columns.first?.messageLock == nil
                && inspector.columns.first?.messageAdmission == inspector.workflowMessageAdmission
        }
        let cancellingSend = try #require(inspector.columns.first?.onSubmitMessage)

        // then — the old route is stale; the reselected node retains the worker's phase policy.
        #expect(!completedSend("old selection", false))
        #expect(inspector.columns.first?.messageLock == nil)
        #expect(cancellingSend("cancel still settling", false))
        await verify(harness.parallel.useCase)
            .sendMessage(.value("current-task"), text: .value("cancel still settling"), now: .value(false))
            .calledEventually(1, before: .seconds(5))

        // when — only the exact cancelled phase locks this worker and rejects its current callback.
        let cancelled = run(status: "cancelled")
        harness.status.value = cancelled
        harness.vm.selectedRun = WorkflowRunModel(raw: cancelled)
        await harness.vm.sidebarTask?.value
        inspector.didAppear()
        harness.parallel.tasksSubject.send([task])
        await waitUntil {
            inspector.columns.first?.messageLock == .runCancelled && !inspector.columns.first!.isBusy
                && inspector.columns.first?.messageAdmission == inspector.workflowMessageAdmission
        }

        // then
        #expect(!cancellingSend("cancelled", false))
        #expect(inspector.columns.first?.inspectorMessageBoxModel.placeholder == MessageBoxDisabledReason.runCancelled.text)
    }
}
