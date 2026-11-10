import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskStatusUnavailableTests

@MainActor struct TaskStatusUnavailableTests {
    @Test func givenReadMetadata_whenProjected_thenOnlyMatchingSuccessHasAuthority() {
        // given / when / then
        let task = TaskDetailVMTests().task()
        #expect(TaskStatusReadAvailability(outcome: nil, taskID: task.taskID) == .unread)
        #expect(TaskStatusReadAvailability(outcome: .init(revision: 1, task: nil), taskID: task.taskID) == .unavailable)
        #expect(TaskStatusReadAvailability(outcome: .init(revision: 2, task: task), taskID: "other") == .unavailable)
        #expect(TaskStatusReadAvailability(outcome: .init(revision: 3, task: task), taskID: task.taskID) == .available)
    }

    @Test func givenUnread_whenMounted_thenDraftRemainsEditableButActionsWait() {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        fixtures.statusReadProvider.value = { _ in nil }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = TaskDetailVMTests().task()
        // when
        harness.sut.didAppear()
        // then
        #expect(!harness.sut.hasStatusAuthority)
        #expect(!harness.sut.isStatusUnavailable)
        #expect(!harness.sut.messageBoxModel.isLocked)
        #expect(harness.sut.messageBoxModel.canEditDraft)
        #expect(!harness.sut.messageBoxModel.canSend)
        #expect(!harness.sut.submitMessage("keep draft"))
        #expect(!harness.sut.canCancel && !harness.sut.canTakeover)
        harness.sut.didDisappear()
    }

    @Test func givenFailureAndEviction_whenInvalidated_thenThreeStatesAndEquivalentRecoveryRemainDistinct() async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task(resumeCommand: "resume latest")
        let read = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: task))
        fixtures.statusReadProvider.value = { _ in read.value }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = task
        harness.snapshotBox.value = task
        harness.sut.didAppear()
        let before = TaskDetailToolbarSnapshot(harness.sut, task: task, showsInspector: false, isRightPane: true)
        // when
        read.value = .init(revision: 2, task: nil)
        fixtures.statusReadSubject.send(())
        await waitUntil { harness.sut.isStatusUnavailable }
        // then
        #expect(harness.sut.stateTreatment?.kind == .statusUnavailable)
        #expect(harness.sut.topBarContent?.badge == .statusUnavailable)
        #expect(harness.sut.topBarContent?.badge.clock == TaskBadgeModel.Clock.none)
        #expect(harness.sut.messageBoxModel.isLocked)
        #expect(harness.sut.messageBoxModel.placeholder == "Unavailable until status can be read")
        #expect(harness.sut.messageBoxModel.hint.isEmpty)
        #expect(harness.sut.messageBoxModel.stopAction == nil)
        let failed = TaskDetailToolbarSnapshot(harness.sut, task: task, showsInspector: false, isRightPane: true)
        #expect(before != failed && !failed.allowsTerminal && !failed.canCancel && failed.resumeCommand == nil)
        #expect(failed.repoPath == "/repo")
        read.value = nil
        fixtures.statusReadSubject.send(())
        await waitUntil { harness.sut.statusReadAvailability == .unread }
        #expect(!harness.sut.isStatusUnavailable && !harness.sut.hasStatusAuthority)
        read.value = .init(revision: 3, task: task)
        fixtures.statusReadSubject.send(())
        await waitUntil { harness.sut.hasStatusAuthority }
        #expect(!harness.sut.isStatusUnavailable && harness.sut.messageBoxModel.canSend)
        #expect(TaskDetailToolbarSnapshot(harness.sut, task: task, showsInspector: false, isRightPane: true) == before)
        harness.sut.didDisappear()
    }

    @Test func givenPublisherWithheld_whenFailureThenEviction_thenRetainedCallbacksCannotReopenActions() async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task(resumeCommand: "resume")
        let read = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: task))
        fixtures.statusReadProvider.value = { _ in read.value }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = task
        harness.snapshotBox.value = task
        harness.sut.didAppear()
        let retainedStop = harness.sut.messageBoxModel.stopAction
        // when / then — no invalidations: display authority intentionally remains stale.
        for outcome in [TaskSnapshotReadOutcome(revision: 2, task: nil), nil] {
            read.value = outcome
            #expect(harness.sut.hasStatusAuthority)
            retainedStop?()
            harness.sut.didTapCancel()
            harness.sut.didTapTakeover()
            harness.sut.didTapCopyResumeCommand()
            harness.sut.cancelQueuedMessage("message")
            #expect(!harness.sut.submitMessage("queue"))
            #expect(!harness.sut.submitMessageNow("now"))
        }
        await drainStatusActions()
        verify(harness.routing).presentStopConfirmation(.any).called(0)
        verify(harness.useCase).beginTakeover(taskID: .any).called(0)
        verify(harness.routing).copyToPasteboard(.any).called(0)
        verify(harness.useCase).cancelMessage(.any, messageID: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenTakeoverDialog_whenFreshReadFailsOrEligibilityChanges_thenConfirmationRefuses() async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task()
        let read = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: task))
        fixtures.statusReadProvider.value = { _ in read.value }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = task
        harness.sut.didAppear()
        var event: ViewEvent?
        let subscription = harness.sut.objectDidPublishViewEvent.publisher.sink { event = $0 }
        harness.sut.didTapTakeover()
        await waitUntil { event?.dialog != nil }
        let dialog = try #require(event?.dialog)
        // when / then
        read.value = .init(revision: 2, task: nil)
        dialog.actions.first?.action()
        read.value = .init(revision: 3, task: TaskDetailVMTests().task(sessionID: nil))
        dialog.actions.first?.action()
        verify(harness.useCase).beginTakeover(taskID: .any).called(0)
        withExtendedLifetime(subscription) {}
        harness.sut.didDisappear()
    }

    @Test func givenFreshPayloadDiffersFromDisplay_whenSendingOrCopying_thenLatestEligibilityAndCommandWin() {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task(resumeCommand: "old")
        let read = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: task))
        fixtures.statusReadProvider.value = { _ in read.value }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = task
        harness.snapshotBox.value = task
        harness.sut.didAppear()
        given(harness.routing).copyToPasteboard(.value("latest")).willReturn(true)
        // when
        read.value = .init(revision: 2, task: TaskDetailVMTests().task(takenOver: true, resumeCommand: "latest"))
        // then
        #expect(!harness.sut.submitMessage("queue") && !harness.sut.submitMessageNow("now"))
        harness.sut.didTapCopyResumeCommand()
        verify(harness.routing).copyToPasteboard(.value("latest")).called(1)
        verify(harness.routing).copyToPasteboard(.value("old")).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenStopSheetAlreadyPresented_whenMetadataFails_thenCapturedConfirmationRefuses() async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task()
        let read = TaskDetailVMTests.Box<TaskSnapshotReadOutcome?>(.init(revision: 1, task: task))
        fixtures.statusReadProvider.value = { _ in read.value }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = task
        var request: TaskStopConfirmation?
        given(harness.routing)
.presentStopConfirmation(.any)
.willProduce { request = $0 }
        harness.sut.didAppear()
        harness.sut.didTapCancel()
        let confirm = try #require(request).confirm
        // when
        read.value = .init(revision: 2, task: nil)
        confirm()
        read.value = nil
        confirm()
        // then
        await drainStatusActions()
        verify(harness.useCase).cancel(.any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenUnchangedCurrentAuthority_whenUnrelatedReadInvalidates_thenNoPresentationRecompute() async {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task()
        fixtures.detailBox.value = task
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        // Let initial observation and replayed outcome deliveries finish before measuring a pulse.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await drainStatusActions()
        let calls = TaskDetailVMTests.Box(0)
        fixtures.recomputeCountEffect.value = { calls.value += 1 }
        // when — a main-queue marker follows the queued Combine delivery.
        fixtures.statusReadSubject.send(())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // then
        #expect(calls.value == 0)
        harness.sut.didDisappear()
    }

    @Test func givenOtherMount_whenStatusMetadataFails_thenExistingControlsRemainIndependent() {
        // given / when / then
        for chrome in [TaskDetailChrome.group, .embedded] {
            let fixtures = TaskDetailVMTests.Fixtures()
            fixtures.statusReadProvider.value = { _ in .init(revision: 1, task: nil) }
            let harness = TaskDetailVMTests().makeSUT(chrome: chrome, fixtures: fixtures)
            harness.detailBox.value = TaskDetailVMTests().task()
            harness.sut.didAppear()
            #expect(harness.sut.hasStatusAuthority && !harness.sut.isStatusUnavailable)
            #expect(harness.sut.messageBoxModel.canSend)
            harness.sut.didDisappear()
        }
    }

    @Test func givenUnavailableWithoutSnapshot_whenProjected_thenFailureWinsAllEarlierClaims() {
        // given / when
        let model = TaskStateTreatment.project(taskID: "known", evidence: nil, isBusy: false,
            canCancel: true, hasResumeCommand: true, isStopping: true, isSettling: true, isStatusUnavailable: true)
        // then
        #expect(model?.kind == .statusUnavailable && model?.isLeadingNotice == true)
        #expect(TaskBadgeModel.statusUnavailable.suffix == nil)
        #expect(TaskBadgeModel.statusUnavailable.tone == .neutral)
    }
}
