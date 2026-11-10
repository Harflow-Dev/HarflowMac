import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskSettlingTests

@MainActor struct TaskSettlingTests {
    @Test func givenCurrentSettlingEvidence_whenReadApplies_thenNoticeRequiresFreshAcknowledgement() async throws {
        // given
        let tests = TaskDetailVMTests()
        var rig = try await tests.openChangesRig(status: "cancelled", logState: .settling, reply: try tests.settlingReply)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.isSettling }
        #expect(rig.sut.stateTreatment?.kind == .settling)
        // when: log evidence invalidates, then recovers in the same scope
        rig.scenario.logState = .final
        tests.publishChanges(rig.scenario, to: rig)
        await waitUntil { !rig.sut.isSettling }
        rig.scenario.logState = .settling
        tests.publishChanges(rig.scenario, to: rig)
        await waitUntil { rig.sut.observationFrames["t1"]?.logState == .settling }
        // then: retained Changes is insufficient until the next scheduled read
        #expect(!rig.sut.isSettling)
        #expect(rig.sut.changesCaptureSettling)
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.sut.isSettling }
        rig.sut.didDisappear()
        #expect(!rig.sut.isSettling)
    }

    @Test(arguments: ["session", "source", "window"])
    func givenSettlingRead_whenScopeChangesInFlight_thenOldGenerationCannotQualify(changedIdentity: String) async throws {
        // given
        let tests = TaskDetailVMTests()
        let rig = try await tests.openChangesRig(status: "cancelled", reply: try tests.settlingReply)
        defer { rig.sut.didDisappear() }
        var scenario = rig.scenario
        scenario.logState = .settling
        let oldScope = scenario.scope
        let newScope = EventObservationScope(sessionID: changedIdentity == "session" ? UUID() : oldScope.sessionID,
                                            sourceID: changedIdentity == "source" ? UUID() : oldScope.sourceID,
                                            windowID: changedIdentity == "window" ? UUID() : oldScope.windowID)
        let capturedScenario = scenario
        rig.script.whileInFlight(0) {
            var changed = capturedScenario
            changed.scope = newScope
            tests.publishChanges(changed, to: rig)
        }
        // when
        tests.publishChanges(scenario, to: rig)
        await waitUntil { rig.script.count == 2 && rig.sut.isSettling }
        // then
        #expect(!rig.script.calls[0].fence())
        #expect(rig.sut.settlingReadEvidence?.scope == newScope)
    }

    @Test func givenSettlingNotice_whenCapWakes_thenQualificationClearsUntilRetry() async throws {
        // given
        let tests = TaskDetailVMTests()
        let rig = try await tests.openChangesRig(status: "cancelled", logState: .settling, reply: try tests.settlingReply)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.isSettling && rig.scheduler.oneShotIntervals == [5] }
        // when
        rig.scheduler.advance(to: rig.scheduler.now().addingTimeInterval(300))
        rig.scheduler.fireOneShot(interval: 5)
        await waitUntil { rig.sut.changesPresentation == .settlingCapped }
        // then
        #expect(!rig.sut.isSettling)
        rig.sut.didTapRetryChanges()
        #expect(!rig.sut.isSettling)
        await waitUntil { rig.sut.isSettling }
    }

    @Test(arguments: [EventObservationCurrentness.reconnecting, .sourceChangePending])
    func givenReadQualification_whenObservationIsNotCurrent_thenNoticeHides(currentness: EventObservationCurrentness) async throws {
        // given
        let tests = TaskDetailVMTests()
        var rig = try await tests.openChangesRig(status: "cancelled", logState: .settling, reply: try tests.settlingReply)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.isSettling }
        // when
        rig.scenario.currentness = currentness
        tests.publishChanges(rig.scenario, to: rig)
        await waitUntil { rig.sut.observationFrames["t1"]?.history.currentness == currentness }
        // then
        #expect(!rig.sut.isSettling)
        #expect(rig.sut.settlingReadEvidence == nil)
    }

    @Test func givenReadQualification_whenLeasePriorTurnFailureOrWrongTask_thenNoticeHides() async throws {
        // given
        let tests = TaskDetailVMTests()
        let rig = try await tests.openChangesRig(status: "cancelled", logState: .settling, reply: try tests.settlingReply)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.isSettling }
        let frame = try #require(rig.sut.observationFrames["t1"])
        // when / then
        rig.sut.changesLifecycle.selectedTurn = "prior"
        #expect(!rig.sut.isSettling)
        rig.sut.changesLifecycle.selectedTurn = nil
        rig.sut.applyObservation(.init(taskID: "wrong", scope: frame.scope, logState: .settling), for: "t1")
        #expect(!rig.sut.isSettling)
        rig.sut.applyObservation(.init(taskID: "t1", scope: frame.scope,
            history: .init(failure: .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "unavailable")), logState: .settling), for: "t1")
        #expect(!rig.sut.isSettling)
        #expect(rig.sut.settlingReadEvidence == nil)
        rig.sut.releaseMemberLease("t1")
        #expect(!rig.sut.isSettling)
    }

    @Test func givenReadQualification_whenSnapshotIsMissingMismatchedOrTakenOver_thenNoticeHides() async throws {
        // given
        let tests = TaskDetailVMTests()
        let rig = try await tests.openChangesRig(status: "cancelled", logState: .settling, reply: try tests.settlingReply)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.isSettling }
        let snapshot = rig.harness.snapshotBox.value
        // when / then
        rig.harness.snapshotBox.value = nil
        #expect(!rig.sut.isSettling)
        rig.harness.snapshotBox.value = SummaryEntryScenario.info(status: "running")
        #expect(!rig.sut.isSettling)
        rig.harness.snapshotBox.value = SummaryEntryScenario.info(id: "other", status: "cancelled")
        #expect(!rig.sut.isSettling)
        rig.harness.snapshotBox.value = SummaryEntryScenario.info(status: "cancelled", fields: ["taken_over": .bool(true)])
        #expect(!rig.sut.isSettling)
        rig.harness.snapshotBox.value = snapshot
        #expect(rig.sut.isSettling)
    }

    @Test func givenSettlingQualification_whenReconstructionOrTakeoverApplies_thenConservativePriorityWins() {
        // given
        var evidence = TaskSnapshotEvidence(status: .completed, takenOver: false, snapshotStatus: .completed,
                                            exitCode: nil, logState: .settling)
        // when / then
        #expect(TaskStateTreatment.project(taskID: "t", evidence: evidence, isBusy: false,
            canCancel: false, hasResumeCommand: false, isSettling: true)?.kind == .reconstructed)
        evidence = .init(status: .cancelled, takenOver: true, snapshotStatus: .cancelled, exitCode: nil, logState: .settling)
        #expect(TaskStateTreatment.project(taskID: "t", evidence: evidence, isBusy: false,
            canCancel: false, hasResumeCommand: false, isSettling: true) == nil)
    }
}
