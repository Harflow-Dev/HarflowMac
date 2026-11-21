import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor @Suite(.serialized)
struct WorkflowRootApprovalScopeTests {
    private let rootID = String(repeating: "a", count: 32)

    @Test func givenMixedRunPages_whenAcquiringRootApprovals_thenRawCursorContinuesUntilDirectWorkerMatch() async throws {
        let run = runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node")
        let scope = WorkflowRootApprovalScope(run: run)
        let child = approvalCaptureRequest(owner: "monitor", id: "child-request", taskID: "child-task",
                                           workflowMetadata: metadata(rootID: "child-run", activationID: "child-attempt", nodeID: "child-node"))
        let staleAttempt = approvalCaptureRequest(owner: "monitor", id: "stale-request", taskID: "worker-task",
                                                  workflowMetadata: metadata(rootID: rootID, activationID: "old-attempt", nodeID: "worker-node"))
        let direct = approvalCaptureRequest(owner: "monitor", id: "direct-request", taskID: "worker-task",
                                            workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let fake = CallerApprovalCaptureFake(requests: [])
        fake.runPages = [
            "<first>": CallerApprovalPage(requests: [child, staleAttempt], nextCursor: "page-2", total: 39),
            "page-2": CallerApprovalPage(requests: [direct], total: 39)
        ]
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)

        #expect(fake.pageCalls.map(\.cursor) == [nil, "page-2"],
                "The raw page with no direct match still advances to its public cursor")
        #expect(controller.requests.map(\.id) == ["direct-request"],
                "Child and stale activation provenance are removed before presentation")
        #expect(controller.total == 1, "The inflated tree-wide total is not presented as a qualified root count")
        #expect(controller.nextCursor == nil)
        controller.stop()
    }

    @Test func givenIssuedWorkerMembership_whenCheckingRequests_thenRequiresExactRootRunAttemptAndNode() throws {
        let scope = WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node"))
        let valid = approvalCaptureRequest(owner: "monitor", taskID: "worker-task",
                                           workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let wrongRoot = approvalCaptureRequest(owner: "monitor", taskID: "worker-task",
                                               workflowMetadata: metadata(rootID: "other-root", activationID: "worker-attempt", nodeID: "worker-node"))
        let wrongRun = approvalCaptureRequest(owner: "monitor", taskID: "worker-task",
                                              workflowMetadata: ["root_workflow_run_id": rootID, "workflow_run_id": "child-run",
                                                                 "workflow_execution_id": "worker-attempt", "workflow_node_id": "worker-node"])
        let wrongNode = approvalCaptureRequest(owner: "monitor", taskID: "worker-task",
                                               workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "other-node"))

        #expect(scope.contains(valid))
        #expect(scope.issuer(for: valid) == "Worker",
                "The fixture uses the public node title before falling back to its ID")
        #expect(!scope.contains(wrongRoot))
        #expect(!scope.contains(wrongRun))
        #expect(!scope.contains(wrongNode))
    }

    @Test func givenRootMembershipGrows_whenReconciling_thenRetainsManualDisclosureCollapse() async {
        let originalRun = runWithWorkers([("task-1", "attempt-1", "node-1"), ("task-2", "attempt-2", "node-2")])
        let originalScope = WorkflowRootApprovalScope(run: originalRun)
        let requests = [
            approvalCaptureRequest(owner: "monitor", id: "request-1", taskID: "task-1",
                                   workflowMetadata: metadata(rootID: rootID, activationID: "attempt-1", nodeID: "node-1")),
            approvalCaptureRequest(owner: "monitor", id: "request-2", taskID: "task-2",
                                   workflowMetadata: metadata(rootID: rootID, activationID: "attempt-2", nodeID: "node-2"))
        ]
        let fake = CallerApprovalCaptureFake(requests: requests)
        fake.runPages = ["<first>": CallerApprovalPage(requests: requests, total: 30)]
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: originalScope)
        #expect(controller.cards.first { $0.id == "request-1" }?.expanded == true,
                "The first qualified pending request is initially disclosed")

        controller.toggle("request-1")
        #expect(controller.cards.first { $0.id == "request-1" }?.expanded == false)
        let added = approvalCaptureRequest(owner: "monitor", id: "request-3", taskID: "task-3",
                                          workflowMetadata: metadata(rootID: rootID, activationID: "attempt-3", nodeID: "node-3"))
        fake.requests = requests + [added]
        fake.runPages["<first>"] = CallerApprovalPage(requests: fake.requests, total: 31)
        let expandedScope = WorkflowRootApprovalScope(run: runWithWorkers([
            ("task-1", "attempt-1", "node-1"), ("task-2", "attempt-2", "node-2"), ("task-3", "attempt-3", "node-3")
        ]))
        controller.updateRootScope(expandedScope)
        await controller.refresh()

        #expect(controller.cards.map(\.id) == ["request-1", "request-2", "request-3"])
        #expect(controller.cards.first { $0.id == "request-1" }?.expanded == false,
                "Adding a direct worker does not undo the caller's manual collapse")
        #expect(controller.cards.first { $0.id == "request-2" }?.expanded == false,
                "Unchanged sibling disclosure state remains independent")
        #expect(controller.cards.first { $0.id == "request-3" }?.expanded == false,
                "A membership refresh does not silently reseed a new first disclosure")
        controller.stop()
    }

    @Test func givenDetailReadSuspended_whenWorkerLeavesRootScope_thenLateDetailCannotReturn() async {
        let request = approvalCaptureRequest(owner: "monitor", id: "removed", taskID: "worker-task",
                                            workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let fake = CallerApprovalCaptureFake(requests: [request])
        fake.suspendsDetails = true
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        let selecting = Task {
            await controller.selectTarget(taskID: nil, workflowRunID: rootID,
                                          rootScope: WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task",
                                                                                              activationID: "worker-attempt",
                                                                                              nodeID: "worker-node")))
        }
        await waitUntil(timeout: 5) { fake.requestedDetails == ["removed"] }
        controller.updateRootScope(WorkflowRootApprovalScope(run: runWithWorkers([])))
        fake.finishDetail(request)
        await selecting.value

        #expect(controller.requests.isEmpty)
        #expect(controller.cards.isEmpty)
        #expect(controller.detail == nil)
        #expect(controller.isCurrentDetail == false)
        controller.stop()
    }

    @Test func givenResponseSuspendedAndRequestRemainsQualified_whenMembershipGrows_thenResponseCompletes() async {
        let request = approvalCaptureRequest(owner: "monitor", id: "retained", taskID: "worker-task",
                                            workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let fake = CallerApprovalCaptureFake(requests: [request])
        fake.supportsCallerResponses = true
        fake.suspendsResponses = true
        fake.runPages = ["<first>": CallerApprovalPage(requests: [request], total: 1)]
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        let scope = WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node"))
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)
        #expect(controller.cards.first?.canRespond == true)
        let response = Task { await controller.respond("approve", requestID: "retained") }
        await waitUntil(timeout: 5) { fake.startedResponses == ["retained"] }

        let expandedScope = WorkflowRootApprovalScope(run: runWithWorkers([
            ("worker-task", "worker-attempt", "worker-node"), ("new-task", "new-attempt", "new-node")
        ]))
        let decided = settledResponse(for: request)
        fake.requests = [decided]
        fake.runPages["<first>"] = CallerApprovalPage(requests: [decided], total: 1)
        controller.updateRootScope(expandedScope)
        fake.finishResponse(decided)
        await response.value

        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: "retained", decision: "approve")])
        #expect(controller.requests.first?.text("disposition") == "decided")
        #expect(controller.isSubmitting == false)
        controller.stop()
    }

    @Test func givenResponseSuspended_whenWorkerLeavesRootScope_thenLateResponseCannotRepopulateIt() async {
        let request = approvalCaptureRequest(owner: "monitor", id: "removed-response", taskID: "worker-task",
                                            workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let fake = CallerApprovalCaptureFake(requests: [request])
        fake.supportsCallerResponses = true
        fake.suspendsResponses = true
        fake.runPages = ["<first>": CallerApprovalPage(requests: [request], total: 1)]
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        let scope = WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node"))
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)
        let response = Task { await controller.respond("approve", requestID: request.id) }
        await waitUntil(timeout: 5) { fake.startedResponses == [request.id] }

        let decided = settledResponse(for: request)
        fake.requests = [decided]
        controller.updateRootScope(WorkflowRootApprovalScope(run: runWithWorkers([])))
        fake.finishResponse(decided)
        await response.value

        #expect(controller.requests.isEmpty)
        #expect(controller.cards.isEmpty)
        #expect(controller.detail == nil)
        #expect(controller.isSubmitting == false)
        controller.stop()
    }

    @Test func givenRootSubmitReserved_whenRefreshArrivesBeforeYield_thenExactResponseWinsOnce() async {
        let request = approvalCaptureRequest(owner: "monitor", id: "queued-response", taskID: "worker-task",
                                            workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let decided = settledResponse(for: request)
        let fake = CallerApprovalCaptureFake(requests: [request])
        fake.supportsCallerResponses = true
        fake.responseResults[request.id] = decided
        fake.runPages = ["<first>": CallerApprovalPage(requests: [request], total: 1)]
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        let scope = WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node"))
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)
        let initialPageCalls = fake.pageCalls.count

        controller.submit("approve", requestID: request.id)
        let wasReservedBeforeYield = controller.isResponseQueued
        await controller.refresh()
        #expect(wasReservedBeforeYield, "The native submit intent reserves this request synchronously")
        fake.requests = [decided]
        fake.runPages["<first>"] = CallerApprovalPage(requests: [decided], total: 1)
        await waitUntil(timeout: 5) {
            fake.responses.count == 1 && controller.requests.first?.text("disposition") == "decided"
        }

        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: request.id, decision: "approve")])
        #expect(fake.pageCalls.count == initialPageCalls + 1,
                "Only the required post-response reconciliation reads again; the concurrent refresh is fenced")
        #expect(!controller.isSubmitting && !controller.isResponseQueued)
        controller.stop()
    }

    @Test func givenSelectedRootIsSuspendedThenReopened_whenTargetIsUnchanged_thenRunQueryReusesPresentation() async {
        let request = approvalCaptureRequest(owner: "monitor", id: "retained", taskID: "worker-task",
                                            workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt", nodeID: "worker-node"))
        let fake = CallerApprovalCaptureFake(requests: [request])
        fake.runPages = ["<first>": CallerApprovalPage(requests: [request], total: 1)]
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        let scope = WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node"))
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)
        controller.toggle("retained")
        let beforeSuspension = controller.cards
        controller.stop()
        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)

        #expect(fake.pageCalls.map(\.workflowRunID) == [rootID, rootID],
                "Reopening the selected root issues one fresh query through its retained controller")
        #expect(controller.cards.first?.id == "retained")
        #expect(controller.cards.first?.expanded == beforeSuspension.first?.expanded,
                "Same-target suspension preserves the manual disclosure choice")
        controller.stop()
    }

    @Test func givenReplacementRootReadCompletesBeforeSuspendedPriorRead_whenSelectingSameTarget_thenLatePageCannotRewind() async {
        let pending = approvalCaptureRequest(owner: "monitor", id: "same-request", taskID: "worker-task",
                                             workflowMetadata: metadata(rootID: rootID, activationID: "worker-attempt",
                                                                        nodeID: "worker-node"))
        let settled = settledResponse(for: pending)
        let fake = CallerApprovalCaptureFake(requests: [pending])
        fake.suspendsFirstRunPage = true
        fake.runPages = ["<first>": CallerApprovalPage(requests: [settled], total: 1)]
        let controller = CallerApprovalController(useCase: fake, pendingDisclosures: true)
        let scope = WorkflowRootApprovalScope(run: runWithWorker(taskID: "worker-task", activationID: "worker-attempt", nodeID: "worker-node"))
        let firstSelection = Task {
            await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)
        }
        await waitUntil(timeout: 5) { fake.pageCalls.count == 1 }

        await controller.selectTarget(taskID: nil, workflowRunID: rootID, rootScope: scope)
        #expect(fake.pageCalls.count == 2, "Selecting the same root starts a replacement one-shot read")
        #expect(controller.requests.first?.text("disposition") == "decided",
                "The replacement read applies the settled public snapshot")
        fake.finishRunPage(CallerApprovalPage(requests: [pending], total: 1))
        await firstSelection.value

        #expect(fake.pageCalls.count == 2)
        #expect(controller.requests.map(\.id) == [pending.id])
        #expect(controller.requests.first?.text("disposition") == "decided",
                "The late result from the superseded page cannot rewind the settled request")
        #expect(controller.cards.first?.pending == false)
        controller.stop()
    }

    @Test func givenRunStatuses_whenCheckingRootPolling_thenPausedNeedsPositiveHoldAndTerminalIsOneShot() {
        let running = WorkflowRunModel(raw: runRaw(status: "running", held: false))
        let pausedWithoutHold = WorkflowRunModel(raw: runRaw(status: "paused", held: false))
        let pausedWithHold = WorkflowRunModel(raw: runRaw(status: "paused", held: true))
        let completedWithStaleHold = WorkflowRunModel(raw: runRaw(status: "completed", held: true))

        #expect(WorkflowRootApprovalScope.shouldPoll(run: running))
        #expect(!WorkflowRootApprovalScope.shouldPoll(run: pausedWithoutHold))
        #expect(WorkflowRootApprovalScope.shouldPoll(run: pausedWithHold))
        #expect(!WorkflowRootApprovalScope.shouldPoll(run: completedWithStaleHold))
    }

    private func runWithWorker(taskID: String, activationID: String, nodeID: String) -> WorkflowRunModel {
        runWithWorkers([(taskID, activationID, nodeID)])
    }

    private func runWithWorkers(_ workers: [(String, String, String)]) -> WorkflowRunModel {
        let nodes = workers.map { _, _, nodeID in
            JSONValue.object(["id": .string(nodeID), "title": .string("Worker")])
        }
        let activations = workers.map { taskID, activationID, nodeID in
            JSONValue.object([
                "id": .string(activationID), "role": .string("node"), "node_id": .string(nodeID),
                "tasks": .array([.object(["task_id": .string(taskID)])])
            ])
        }
        return WorkflowRunModel(raw: [
            "workflow_run_id": .string(rootID), "root_workflow_run_id": .string(rootID),
            "status": .string("running"), "kind": .string("workflow"),
            "definition": .object(["nodes": .array(nodes)]), "activations": .array(activations)
        ])
    }

    private func runRaw(status: String, held: Bool) -> [String: JSONValue] {
        ["workflow_run_id": .string(rootID), "root_workflow_run_id": .string(rootID),
         "status": .string(status), "kind": .string("workflow"),
         "steering_summary": .object(["hold": .bool(held)])]
    }

    private func settledResponse(for request: CallerApprovalRequest) -> CallerApprovalRequest {
        var raw = request.raw
        raw["disposition"] = .string("decided")
        raw["delivery"] = .string("sent")
        raw["owner_revision"] = .number(Double((request.revision ?? 0) + 1))
        raw["decision"] = .string("approve")
        raw["decided_by"] = .string("caller")
        raw["responder"] = .string("monitor")
        return CallerApprovalRequest(raw: raw)
    }

    private func metadata(rootID: String, activationID: String, nodeID: String) -> [String: String] {
        ["root_workflow_run_id": rootID, "workflow_run_id": rootID,
         "workflow_execution_id": activationID, "workflow_node_id": nodeID]
    }
}
