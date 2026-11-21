import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
struct WorkflowSteeringQueueTests {
    private let rootID = String(repeating: "a", count: 32)

    @Test func givenFailedRootAndExplicitlyMissingSteeringWithMessagingSupported_whenQueued_thenUsesIssuedOrchestratorTask() async {
        // given
        let harness = makeHarness(statusFailure: missingSteeringCapability())
        defer { harness.sut.didDisappear() }
        given(harness.useCase)
.command(.value("send"), options: .any, positionals: .any, runtime: .any)
            .willReturn(["status": .string("queued"), "message_id": .string("queued-message")])
        await establishSteeringRead(harness)

        // when
        #expect(harness.sut.steeringUnsupported)
        #expect(harness.sut.steeringFailedQueue)
        #expect(harness.sut.submitActivityMessage("Keep the recovery message", now: false))

        // then
        await verify(harness.useCase)
.command(
            .value("send"),
            options: .value(["--monitor", "--delivery=queue", "--task-id=orchestrator-task"]),
            positionals: .value([rootID, "Keep the recovery message"]), runtime: .any
        )
.calledEventually(1, before: .seconds(5))
        await verify(harness.useCase)
.command(
            .value("send"), options: .any, positionals: .matching { $0.contains("--delivery=now") }, runtime: .any
        )
.called(0)
    }

    @Test func givenFailedRootAndCurrentSteeringWithoutHold_whenQueued_thenUsesIssuedOrchestratorTask() async throws {
        let harness = makeHarness(statusFailure: nil, currentStatus: try WorkflowSteeringTestFixtures.status(
            rootID: rootID, eligibleActions: ["open"]
        ))
        defer { harness.sut.didDisappear() }
        given(harness.useCase)
.steeringHistory(observation: .any, cursor: .any)
            .willReturn(try WorkflowSteeringTestFixtures.history(rootID: rootID, items: []))
        given(harness.useCase)
            .command(.value("send"), options: .any, positionals: .any, runtime: .any)
            .willReturn(["status": .string("queued"), "message_id": .string("queued-message")])
        await establishSteeringRead(harness, expectCurrentStatus: true)

        #expect(!harness.sut.steeringUnsupported)
        #expect(harness.sut.steeringObservation?.status.episodes.isEmpty == true)
        #expect(harness.sut.steeringFailedQueue)
        #expect(harness.sut.submitActivityMessage("Queue after a current no-hold read", now: false))

        await verify(harness.useCase)
            .command(.value("send"),
                     options: .value(["--monitor", "--delivery=queue", "--task-id=orchestrator-task"]),
                     positionals: .value([rootID, "Queue after a current no-hold read"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
        await verify(harness.useCase)
            .command(.value("send"), options: .any, positionals: .matching { $0.contains("--delivery=now") }, runtime: .any)
            .called(0)
    }

    @Test func givenFailedRootAndGenericSteeringTransportFailure_whenQueued_thenRemainsFenced() async {
        // given
        let harness = makeHarness(statusFailure: ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "offline"))
        defer { harness.sut.didDisappear() }
        await establishSteeringRead(harness)

        // when / then
        #expect(!harness.sut.steeringUnsupported)
        #expect(!harness.sut.steeringFailedQueue)
        #expect(!harness.sut.submitActivityMessage("Do not queue on an unknown read failure", now: false))
        await verify(harness.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).called(0)
    }

    @Test func givenFailedRootWithPositiveHoldAndMissingSteeringCapability_whenQueued_thenRemainsFenced() async {
        // given
        let harness = makeHarness(statusFailure: missingSteeringCapability(), positiveHold: true)
        defer { harness.sut.didDisappear() }
        await establishSteeringRead(harness)

        // when / then
        #expect(harness.sut.steeringUnsupported)
        #expect(harness.sut.steering.isHeld)
        #expect(!harness.sut.steeringFailedQueue)
        #expect(!harness.sut.submitActivityMessage("Do not bypass a known hold", now: false))
        await verify(harness.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).called(0)
    }

    @Test func givenFailedRootWithMissingSteeringAndMessagingCapability_whenQueued_thenMessagingLockStillWins() async {
        // given
        let harness = makeHarness(statusFailure: missingSteeringCapability(), messagingSupported: false)
        defer { harness.sut.didDisappear() }
        await establishSteeringRead(harness)

        // when / then
        #expect(harness.sut.steeringUnsupported)
        #expect(harness.sut.messagingUnsupported)
        #expect(!harness.sut.steeringFailedQueue)
        #expect(!harness.sut.submitActivityMessage("Do not queue without messaging.v1", now: false))
        await verify(harness.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).called(0)
    }

    private struct Harness {
        let sut: WorkflowVM
        let useCase: MockWorkflowUseCase
    }

    private func makeHarness(statusFailure: ToolError?, currentStatus: WorkflowSteeringStatus? = nil, positiveHold: Bool = false,
                             messagingSupported: Bool = true) -> Harness {
        let runtime = QualificationRuntimeToken(client: CtlClient(
            executable: "/fixture/ctl", environment: ["HOME": "/tmp/harflow-stage3-steering-tests"]
        ))
        let harness = WorkflowTests().makeVM(runtime: runtime)
        let run = failedRoot(positiveHold: positiveHold)
        harness.sut.selectedRun = WorkflowRunModel(raw: run)
        harness.sut.primaryNodeID = WorkflowStandalone.orchestratorID
        harness.sut.selectedNodeIDs = [WorkflowStandalone.orchestratorID]
        harness.sut.runSidebar = WorkflowRunSidebarPresentation.build(
            run: run, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil
        )
        harness.sut.messagingSupported = messagingSupported
        given(harness.useCase)
            .command(.value("status"), options: .value(["--monitor-view", "--snapshot"]),
                     positionals: .value([rootID]), runtime: .value(runtime))
            .willReturn(run)
        given(harness.useCase).steeringAttempts(rootID: .value(rootID)).willReturn([])
        given(harness.useCase).isSteeringCurrent(.any).willReturn(true)
        if let currentStatus {
            given(harness.useCase).steeringObservation(rootID: .value(rootID)).willReturn(
                WorkflowSteeringObservation(status: currentStatus, runtime: runtime, generation: 0, readOrdinal: 1, id: UUID())
            )
        } else {
            given(harness.useCase).steeringObservation(rootID: .value(rootID)).willThrow(
                statusFailure ?? .unsupportedCommand(tool: "harflow-ctl", command: "workflow-steering-status", detail: "Fixture has no status")
            )
        }
        return Harness(sut: harness.sut, useCase: harness.useCase)
    }

    private func establishSteeringRead(_ harness: Harness, expectCurrentStatus: Bool = false) async {
        harness.sut.didSubscribe = true
        harness.sut.startSteeringObservation()
        // The visibility publisher delivers its initial value asynchronously. Awaiting the
        // task property immediately can race that delivery and observe nil before any read starts.
        await waitUntil(timeout: 5) {
            !harness.sut.steeringRevalidating && (expectCurrentStatus
                ? harness.sut.steeringObservation != nil : harness.sut.steering.partialHistory)
        }
        await verify(harness.useCase)
.steeringObservation(rootID: .value(rootID))
            .calledEventually(.atLeastOnce, before: .seconds(5))
        #expect(expectCurrentStatus ? harness.sut.steeringObservation != nil : harness.sut.steering.partialHistory,
                "The current steering read outcome is applied before assertions")
    }

    private func missingSteeringCapability() -> ToolError {
        .unsupportedCommand(tool: "harflow-ctl", command: "workflow-steering-status",
                            detail: "Missing capability workflow-steering-read.v1")
    }

    private func failedRoot(positiveHold: Bool) -> [String: JSONValue] {
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string(rootID),
            "root_workflow_run_id": .string(rootID),
            "kind": .string("workflow"),
            "status": .string("failed"),
            "definition": .object(["nodes": .array([])]),
            // swiftformat:disable:next trailingCommas
            "activations": .array([.object([
                "id": .string("orchestrator-execution"),
                "role": .string("orchestrator"),
                "status": .string("running"),
                // swiftformat:disable:next trailingCommas
                "tasks": .array([.object(["task_id": .string("orchestrator-task"), "status": .string("running")])])
            // swiftformat:disable:next trailingCommas
            ])])
        ]
        if positiveHold { raw["steering_summary"] = .object(["hold": .bool(true)]) }
        return raw
    }
}
