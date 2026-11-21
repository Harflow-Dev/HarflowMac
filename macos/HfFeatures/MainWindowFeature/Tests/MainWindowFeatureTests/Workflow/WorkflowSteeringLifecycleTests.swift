import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowSteeringLifecycleTests

@MainActor
struct WorkflowSteeringLifecycleTests {
    private let rootID = WorkflowSteeringTestFixtures.rootRunID
    private let otherRootID = WorkflowSteeringTestFixtures.workerID

    @Test func givenRootDrafts_whenSelectedRootChanges_thenDraftsRemainScopedToTheirRoot() {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.selectedRun = WorkflowRunModel(raw: root(rootID))
        harness.sut.selectedNodeID = WorkflowStandalone.orchestratorID
        harness.sut.steeringDraft = "Draft for first root"

        // when
        harness.sut.selectedRun = WorkflowRunModel(raw: root(otherRootID))

        // then
        #expect(harness.sut.steeringDraft.isEmpty)
        harness.sut.steeringDraft = "Draft for second root"
        harness.sut.selectedRun = WorkflowRunModel(raw: root(rootID))
        #expect(harness.sut.steeringDraft == "Draft for first root")
        harness.sut.selectedRun = WorkflowRunModel(raw: root(otherRootID))
        #expect(harness.sut.steeringDraft == "Draft for second root")
    }

    @Test func givenSelectedRun_whenSelectionIsNestedWorkerOrBuilder_thenSteeringNeverOwnsComposer() {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.selectedNodeID = WorkflowStandalone.orchestratorID

        // when / then: a regular root owns the shared composer only for its selected orchestrator.
        harness.sut.selectedRun = WorkflowRunModel(raw: root(rootID))
        #expect(harness.sut.steeringOwnsComposer)
        harness.sut.selectedNodeID = "worker-node"
        #expect(!harness.sut.steeringOwnsComposer)
        harness.sut.selectedNodeID = WorkflowStandalone.orchestratorID
        harness.sut.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string(otherRootID),
            "root_workflow_run_id": .string(rootID),
            "parent_workflow_run_id": .string(rootID),
            "kind": .string("workflow"),
            "status": .string("running")
        ])
        #expect(!harness.sut.steeringOwnsComposer)
        harness.sut.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string(rootID),
            "root_workflow_run_id": .string(rootID),
            "kind": .string("builder"),
            "status": .string("running")
        ])
        #expect(!harness.sut.steeringOwnsComposer)
    }

    @Test func givenParentlessRun_whenRootIDIsOmitted_thenUsesOwnIDButRejectsContradictoryRoot() {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.selectedNodeID = WorkflowStandalone.orchestratorID
        var omittedRoot = root(rootID)
        omittedRoot.removeValue(forKey: "root_workflow_run_id")

        // when / then
        harness.sut.selectedRun = WorkflowRunModel(raw: omittedRoot)
        #expect(harness.sut.steeringOwnsComposer, "A parentless run with no explicit root identifies itself")
        var contradictoryRoot = root(rootID)
        contradictoryRoot["root_workflow_run_id"] = .string(otherRootID)
        harness.sut.selectedRun = WorkflowRunModel(raw: contradictoryRoot)
        #expect(!harness.sut.steeringOwnsComposer, "An explicit different root must not inherit root controls")
    }

    @Test func givenVisibleRootAndDraft_whenWindowHides_thenReadLeaseIsRevokedAndDraftSurvives() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let visibility = try #require(harness.sut.visibility as? FakeMonitorVisibility)
        defer { harness.sut.didDisappear() }
        harness.sut.selectedRun = WorkflowRunModel(raw: root(rootID))
        harness.sut.selectedNodeID = WorkflowStandalone.orchestratorID
        harness.sut.steeringDraft = "Keep this draft while hidden"
        given(harness.useCase).steeringObservation(rootID: .value(rootID)).willThrow(
            ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "offline")
        )
        let previousLease = harness.sut.steeringLease
        harness.sut.didSubscribe = true
        harness.sut.startSteeringObservation()

        // when
        visibility.setMainWindowVisible(false)
        await Task.yield()
        await Task.yield()

        // then
        #expect(harness.sut.steeringLease != previousLease)
        #expect(!harness.sut.steeringCanRead)
        #expect(harness.sut.steeringDraft == "Keep this draft while hidden")
    }

    private func root(_ id: String) -> [String: JSONValue] {
        [
            "workflow_run_id": .string(id),
            "root_workflow_run_id": .string(id),
            "kind": .string("workflow"),
            "status": .string("running")
        ]
    }
}
