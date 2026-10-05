import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// Redesign phase 5, settled plan D7: the composer's disabled copy comes from an explicit reason.
extension TaskDetailVMTests {

    private func shownModel(_ task: TaskInfo) async -> MessageBoxModel {
        let harness = makeSUT()
        harness.detailBox.value = task
        harness.sut.didAppear()
        harness.tasksSubject.send([task])
        await waitUntil { harness.sut.task != nil }
        return harness.sut.messageBoxModel
    }

    @Test func givenManagedWorkflowTask_whenSubmittingDirectMessage_thenComposerIsLockedAndSubmitRefuses() async throws {
        // given
        let harness = makeSUT()
        var raw = task(status: "running", liveInput: true, takenOver: false).raw
        raw["workflow_run_id"] = .string("run")
        raw["workflow_status"] = .string("running")
        raw["workflow_settling"] = .bool(false)
        let managed = try #require(TaskInfo(.object(raw)))
        harness.detailBox.value = managed
        harness.sut.didAppear()
        harness.tasksSubject.send([managed])
        await waitUntil { harness.sut.task != nil }
        // when / then
        #expect(harness.sut.messageBoxModel.isLocked)
        #expect(!harness.sut.messageBoxModel.canSend && !harness.sut.messageBoxModel.canContinue)
        #expect(!harness.sut.submitMessage("Bypass the workflow"))
        harness.sut.didDisappear()
    }

    @Test func givenARunningTaskWithoutLiveInput_whenRenderingTheComposer_thenItIsLockedWithTheLiveInputCopy() async {
        // given / when
        let model = await shownModel(task(status: "running", liveInput: false, takenOver: false))

        // then
        #expect(model.placeholder == "Messages are off — this task wasn't started with live input")
        #expect(model.isLocked)
        #expect(!model.canSend)
        #expect(!model.canContinue)
    }

    @Test func givenARunningTakenOverTaskWithLiveInput_whenRenderingTheComposer_thenItIsLockedWithTheTakenOverCopy() async {
        // given / when
        let model = await shownModel(task(status: "running", liveInput: true, takenOver: true))

        // then
        #expect(model.placeholder == "Messages are off — you took this task over in Terminal")
        #expect(model.isLocked)
        #expect(!model.canSend)
    }

    @Test func givenARunningTakenOverTaskWithoutLiveInput_whenRenderingTheComposer_thenTheTakenOverCopyWins() async {
        // given / when
        let model = await shownModel(task(status: "running", liveInput: false, takenOver: true))

        // then
        #expect(model.placeholder == "Messages are off — you took this task over in Terminal")
        #expect(model.isLocked)
    }

    @Test func givenAFinishedTaskWithNoSession_whenRenderingTheComposer_thenItKeepsTheExistingCopyWithoutALock() async {
        // given / when
        let model = await shownModel(task(status: "completed", sessionID: nil))

        // then
        #expect(model.placeholder == "This task has no session to continue.")
        #expect(!model.isLocked)
        #expect(!model.canContinue)
    }

    @Test func givenARunningLiveInputTask_whenRenderingTheComposer_thenItIsOpenAndUnlocked() async {
        // given / when
        let model = await shownModel(task(status: "running", liveInput: true))

        // then
        #expect(model.canSend)
        #expect(!model.isLocked)
        #expect(model.placeholder == "Message this task while it runs…")
    }

    @Test func givenAFinishedTaskWithASession_whenRenderingTheComposer_thenItOffersAFollowUp() async {
        // given / when
        let model = await shownModel(task(status: "completed"))

        // then
        #expect(model.canContinue)
        #expect(!model.isLocked)
        #expect(model.buttonLabel == "Continue")
    }

    @Test func givenEachDisabledReason_whenAskingForLocks_thenOnlyTheMessagesAreOffReasonsLock() {
        // given / when / then
        #expect(MessageBoxDisabledReason.notLiveInput.showsLock)
        #expect(MessageBoxDisabledReason.takenOver.showsLock)
        #expect(!MessageBoxDisabledReason.noSession.showsLock)
        #expect(!MessageBoxDisabledReason.other.showsLock)
    }
}
