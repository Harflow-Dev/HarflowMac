import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - PendingRecordedAdmissionTests

@Suite struct PendingRecordedAdmissionTests {
    @Test func givenFreshExactOrdinaryStatus_whenAdmitted_thenTaskIsInHistoryBeforeReturn() async throws {
        // given
        let harness = PendingLaunchHarness()
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        let runtime = QualificationRuntimeToken(client: harness.selected.value)
        let gate = PendingLaunchAdmissionGate()
        // when
        let task = try await list.admitRecorded("target", runtime: runtime, gate: gate)
        // then
        #expect(task.taskID == "target")
        #expect(list.task("target")?.taskID == "target")
        #expect(await harness.runner.calls.filter { $0.first == "status" }.count == 1)
    }

    @Test func givenDelayedOrdinaryStatus_whenSelectionGateRevoked_thenNoHistoryOrTitlePublicationOccurs() async throws {
        // given
        let harness = PendingLaunchHarness()
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        let gate = PendingLaunchAdmissionGate()
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch, command: "status")
        let runtime = QualificationRuntimeToken(client: harness.selected.value)
        let counts = LockedBox(0)
        let subscription = list.tasksPublisher().sink { _ in counts.mutate { $0 += 1 } }
        let initial = counts.value
        let task = Task { try await list.admitRecorded("target", runtime: runtime, gate: gate) }
        await latch.waitForArrival()
        // when
        gate.revoke()
        await latch.release()
        _ = await task.result
        // then
        #expect(list.task("target") == nil && list.titles.isEmpty)
        #expect(counts.value == initial)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenDelayedOldRuntimeStatus_whenRuntimeSwitches_thenNoHistoryPollutionOccurs() async throws {
        // given
        let harness = PendingLaunchHarness()
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        let gate = PendingLaunchAdmissionGate()
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch, command: "status")
        let runtime = QualificationRuntimeToken(client: harness.selected.value)
        let task = Task { try await list.admitRecorded("target", runtime: runtime, gate: gate) }
        await latch.waitForArrival()
        // when
        let replacement = CtlClient(executable: "/fixture/other/ctl", environment: [:], runner: harness.runner)
        harness.selected.mutate { $0 = replacement }
        await latch.release()
        _ = await task.result
        // then
        #expect(list.task("target") == nil && list.tasks.isEmpty)
    }

    @Test func givenAlreadyRevokedGate_whenAdmissionRequested_thenNoStatusCommandStarts() async {
        // given
        let harness = PendingLaunchHarness()
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        let gate = PendingLaunchAdmissionGate()
        gate.revoke()
        // when
        _ = try? await list.admitRecorded("target", runtime: QualificationRuntimeToken(client: harness.selected.value), gate: gate)
        // then
        #expect(await harness.runner.calls.isEmpty)
    }
}
