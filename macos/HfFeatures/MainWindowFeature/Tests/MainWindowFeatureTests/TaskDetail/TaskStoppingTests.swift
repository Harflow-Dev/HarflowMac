import Combine
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStoppingTests

@MainActor struct TaskStoppingTests {
    @Test func givenStandaloneRunningComposer_whenDraftAndLifecycleChange_thenTrailingModeKeepsAdmissionMeaning() {
        func composer(_ draft: String, canSend: Bool = false, allowsDraftEditing: Bool = false,
                      isLocked: Bool = false, isBusy: Bool = false, isStopping: Bool = false,
                      isRunning: Bool = true) -> MessageBoxView {
            var model = MessageBoxModel(canSend: canSend, canContinue: false, isBusy: isBusy,
                label: "Message this task", hint: "", placeholder: "Queue a message…", buttonLabel: "Send")
            model.isRunning = isRunning
            model.isStopping = isStopping
            model.isLocked = isLocked
            model.allowsDraftEditing = allowsDraftEditing
            model.stopAction = {}
            return MessageBoxView(model: model, style: .transcript, isStandalone: true,
                                  text: .constant(draft)) { _ in false }
        }

        #expect(composer("").trailingMode == .stop)
        #expect(composer(" \n\t ").trailingMode == .stop)
        #expect(composer(" draft ", canSend: true).trailingMode == .send)
        #expect(composer(" draft ", allowsDraftEditing: true, isBusy: true).trailingMode == .send)
        #expect(composer(" retained ", isLocked: true).trailingMode == .stop)
        #expect(composer(" retained ", isStopping: true).trailingMode == .stopping)
        #expect(composer("", isRunning: false).trailingMode == .send)
    }

    private func snapshot(owner: String = "alive", status: String = "running", taken: Bool = false) -> TaskInfo {
        TaskInfo(.object(["task_id": .string("abc12345"), "backend": .string("claude"),
            "status": .string(status), "taken_over": .bool(taken),
            "supervision": .object(["owner_state": .string(owner)])]))!
    }

    @Test func givenAcceptedStop_whenRemounted_thenInitialQueryRestoresStopping() async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        fixtures.stopping.value = true
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        let running = snapshot()
        harness.detailBox.value = running
        harness.snapshotBox.value = running
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.isStopping }
        harness.sut.didDisappear()
        let remount = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        remount.sut.didAppear()
        await waitUntil { remount.sut.isStopping }
        // then
        #expect(remount.sut.isStopping)
        remount.sut.didDisappear()
        harness.sut.didAppear()
        await waitUntil { harness.sut.messagingSupported == true }
        #expect(harness.sut.isStopping)
        #expect(harness.sut.stateTreatment?.kind == .stopping)
        #expect(harness.sut.messageBoxModel.isStopping)
        #expect(!harness.sut.messageBoxModel.canSend)
        #expect(harness.sut.messageBoxModel.stopAction != nil)
        harness.sut.didDisappear()
    }

    @Test func givenStoppingInvalidations_whenLatestQueryChanges_thenPresentationReadsLatestValue() async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = snapshot()
        harness.snapshotBox.value = snapshot()
        harness.sut.didAppear()
        harness.tasksSubject.send([snapshot()])
        await waitUntil { harness.sut.task != nil }
        // when
        fixtures.stopping.value = true
        fixtures.stoppingSubject.send(())
        await waitUntil { harness.sut.isStopping }
        fixtures.stopping.value = false
        fixtures.stoppingSubject.send(())
        // then
        await waitUntil { !harness.sut.isStopping }
        #expect(!harness.sut.isStopping)
        #expect(harness.sut.stateTreatment == nil)
        #expect(harness.sut.messageBoxModel.canSend)
        harness.sut.didDisappear()
    }

    @Test(arguments: ["dead", "undecidable", "unknown"])
    func givenAcknowledgement_whenOwnerIsNotAlive_thenStoppingDoesNotHideWarnings(owner: String) async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        fixtures.stopping.value = true
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = snapshot(owner: owner)
        harness.snapshotBox.value = snapshot(owner: owner)
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([snapshot(owner: owner)])
        await waitUntil { harness.sut.task != nil }
        // then
        #expect(!harness.sut.isStopping)
        #expect(harness.sut.stateTreatment?.kind == (owner == "dead" ? .ownerLost : owner == "undecidable" ? .unverified : nil))
        harness.sut.didDisappear()
    }

    @Test func givenAcknowledgement_whenEvidenceUnavailableTakenOverOrOtherMount_thenStoppingIsSuppressed() async {
        // given / when / then
        for chrome in [TaskDetailChrome.standalone, .group, .embedded] {
            let fixtures = TaskDetailVMTests.Fixtures()
            fixtures.stopping.value = true
            let harness = TaskDetailVMTests().makeSUT(chrome: chrome, fixtures: fixtures)
            harness.detailBox.value = snapshot()
            harness.sut.didAppear()
            harness.tasksSubject.send([snapshot()])
            await waitUntil { harness.sut.task != nil }
            #expect(!harness.sut.isStopping)
            harness.snapshotBox.value = snapshot(taken: true)
            fixtures.stoppingSubject.send(())
            await waitUntil { harness.sut.inspectorModel?.hasSnapshot == true }
            #expect(!harness.sut.isStopping)
            harness.sut.didDisappear()
        }
    }

    @Test func givenAcknowledgement_whenSnapshotIsForDifferentMemberOrStatus_thenStoppingIsSuppressed() async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        fixtures.stopping.value = true
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = snapshot()
        harness.snapshotBox.value = TaskDetailVMTests().task(id: "earlier-member")
        harness.sut.didAppear()
        harness.tasksSubject.send([snapshot()])
        await waitUntil { harness.sut.task != nil }
        // when / then
        #expect(!harness.sut.isStopping)
        harness.snapshotBox.value = snapshot(status: "completed")
        fixtures.stoppingSubject.send(())
        await waitUntil { harness.sut.inspectorModel?.detail.status == .completed }
        #expect(!harness.sut.isStopping)
        harness.sut.didDisappear()
    }

    @Test func givenStoppingEvidence_whenProjected_thenNoticeLeadsWithStableIdentity() {
        // given
        let evidence = TaskSnapshotEvidence(status: .running, takenOver: false, snapshotStatus: .running,
            exitCode: nil, logState: nil, ownerState: "alive")
        // when
        let notice = TaskStateTreatment.project(taskID: "task", evidence: evidence, isBusy: false,
            canCancel: true, hasResumeCommand: false, isStopping: true)
        // then
        #expect(notice?.kind == .stopping)
        #expect(notice?.isLeadingNotice == true)
        #expect(notice?.id == "activity-task-state-task")
        #expect(notice != TaskStateTreatment(taskID: "task", kind: .reconstructed))
    }
}
