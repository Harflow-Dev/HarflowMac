import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskContinuationUITests

@MainActor @Suite struct TaskContinuationUITests {
    @Test func givenObservedExitAndPairedSupport_whenContinueTappedTwice_thenOneSharedAttemptLocksActions() async {
        // given
        let fixture = ContinuationUIFixture()
        let vm = fixture.vm.sut
        vm.didAppear()
        await waitUntil { vm.continuationPresentation?.canContinue == true }
        // when
        vm.didTapContinue(taskID: "abc12345")
        vm.didTapContinue(taskID: "abc12345")
        // then
        #expect(vm.continuationPresentation?.phase == .starting)
        #expect(!vm.submitMessage("retained draft"))
        await waitUntil { fixture.owner.startCount == 1 }
        #expect(!vm.canCancel && !vm.canTakeover && vm.resumeCommand == nil)
        #expect(vm.messageBoxModel.isLocked)
        vm.didDisappear()
    }

    @Test func givenUnknownOwnerWithoutPublication_whenOldHandlersRun_thenMutationsRefuseSynchronously() async {
        // given
        let fixture = ContinuationUIFixture(status: "running")
        let vm = fixture.vm.sut
        vm.didAppear()
        await waitUntil { vm.task != nil }
        fixture.owner.install(.uncertain(.inconsistentEnvelope(exitCode: 3, detail: "unknown")))
        // when / then — no owner publication reaches the VM before these callbacks.
        #expect(!vm.submitMessage("queued"))
        #expect(!vm.submitMessageNow("now"))
        vm.cancelQueuedMessage("message")
        vm.didTapCopyResumeCommand()
        vm.didTapTakeover()
        vm.didTapCancel()
        await withCheckedContinuation { continuation in Task { @MainActor in continuation.resume() } }
        verify(fixture.vm.routing).presentStopConfirmation(.any).called(0)
        verify(fixture.vm.useCase).cancelMessage(.any, messageID: .any).called(0)
        verify(fixture.vm.useCase).send(.any, text: .any).called(0)
        verify(fixture.vm.useCase).beginTakeover(taskID: .any).called(0)
        verify(fixture.vm.routing).copyToPasteboard(.any).called(0)
        vm.didDisappear()
    }

    @Test func givenChangedRawBindingBeforePublication_whenOldActionsRun_thenTheyCannotUsePriorStatus() async {
        // given
        let fixture = ContinuationUIFixture(status: "running")
        let vm = fixture.vm.sut
        vm.didAppear()
        await waitUntil { vm.task != nil }
        // when — status and owner publications are deliberately withheld.
        fixture.fixtures.continuationRuntime.value = QualificationRuntimeToken(
            client: CtlClient(executable: "/fixture/replaced/harflow-ctl", environment: [:]))
        #expect(!vm.submitMessage("old status, new runtime"))
        vm.didTapTakeover()
        vm.didTapCopyResumeCommand()
        fixture.fixtures.continuationRuntime.value = nil
        #expect(!vm.submitMessageNow("old status, unavailable runtime"))
        // then
        verify(fixture.vm.useCase).send(.any, text: .any).called(0)
        verify(fixture.vm.useCase).beginTakeover(taskID: .any).called(0)
        verify(fixture.vm.routing).copyToPasteboard(.any).called(0)
        vm.didDisappear()
    }

    @Test func givenUnknownAttempt_whenRuntimeTemporarilyUnavailableAndSupportFails_thenRemountKeepsLock() async {
        // given
        let fixture = ContinuationUIFixture(supported: false)
        fixture.owner.install(.uncertain(.inconsistentEnvelope(exitCode: 3, detail: "unknown")))
        let vm = fixture.vm.sut
        vm.didAppear()
        await waitUntil { vm.continuationPresentation?.phase == .unknown }
        // when
        fixture.fixtures.continuationRuntime.value = nil
        #expect(!vm.submitMessage("must stay locked"))
        vm.recompute()
        #expect(vm.continuationPresentation?.phase == .unknown)
        vm.didDisappear()
        vm.didAppear()
        // then
        await waitUntil { vm.continuationPresentation?.phase == .unknown }
        #expect(vm.messageBoxModel.isLocked)
        #expect(fixture.owner.startCount == 0)
        vm.didDisappear()
    }

    @Test func givenUnknownAttempt_whenCheckIsEmpty_thenLockRemainsAndLaunchNeverRepeats() async throws {
        // given
        let fixture = ContinuationUIFixture()
        fixture.owner.install(.uncertain(.inconsistentEnvelope(exitCode: 3, detail: "unknown")))
        fixture.vm.sut.didAppear()
        let attemptID = try #require(fixture.owner
.state(for: .init(runtime: fixture.owner.runtime,
                                                                 conversationID: "abc12345", sourceTaskID: "abc12345"))?.id)
        // when
        fixture.vm.sut.didTapCheckContinuation(taskID: "abc12345", attemptID: attemptID)
        await waitUntil { fixture.owner.checkCount > 0 }
        // then
        #expect(fixture.vm.sut.continuationPresentation?.locksActions == true)
        #expect(fixture.owner.startCount == 0)
        fixture.vm.sut.didDisappear()
    }

    @Test func givenRetainedUnknown_whenGlobalReadPulseArrives_thenOnlyNewCurrentReadRetriesObservation() async {
        // given
        let fixture = ContinuationUIFixture()
        fixture.owner.install(.uncertain(.inconsistentEnvelope(exitCode: 3, detail: "unknown")))
        let observations = TaskDetailVMTests.Box(0)
        let revision = TaskDetailVMTests.Box<UInt64>(1)
        fixture.fixtures.statusReadProvider.value = { _ in
            fixture.fixtures.detailBox.value.map { TaskSnapshotReadOutcome(revision: revision.value, task: $0) }
        }
        fixture.fixtures.successorObservationEffect.value = { _ in observations.value += 1; return false }
        let vm = fixture.vm.sut
        vm.didAppear()
        await waitUntil { observations.value > 0 && vm.continuationSession.adoptionRead == nil }
        let initial = observations.value
        // when — global/unrelated pulse leaves this member's admitted read unchanged.
        fixture.fixtures.statusReadSubject.send(())
        await Task.yield()
        #expect(observations.value == initial)
        revision.value += 1
        fixture.fixtures.statusReadSubject.send(())
        // then — exactly one new bounded read, without a new launch.
        await waitUntil { observations.value > initial }
        #expect(observations.value == initial + 1 && fixture.owner.startCount == 0)
        vm.didDisappear()
    }

    @Test func givenMissingObservedExitOrMissingPair_whenPrepared_thenContinueIsNotOffered() async {
        // given
        for fixture in [ContinuationUIFixture(exit: false), ContinuationUIFixture(supported: false)] {
            fixture.vm.sut.didAppear()
            // when
            await waitUntil { fixture.vm.sut.task != nil }
            fixture.vm.sut.didTapContinue(taskID: "abc12345")
            // then
            #expect(fixture.vm.sut.continuationPresentation == nil)
            #expect(fixture.owner.startCount == 0)
            fixture.vm.sut.didDisappear()
        }
    }

    @Test func givenContinueFromOldRowOrOtherMount_whenInvoked_thenNoLaunchOccurs() async {
        // given
        let fixture = ContinuationUIFixture()
        fixture.vm.sut.didAppear()
        await waitUntil { fixture.vm.sut.continuationPresentation?.canContinue == true }
        // when / then
        fixture.vm.sut.didTapContinue(taskID: "old-full-task-id")
        #expect(fixture.owner.startCount == 0)
        fixture.vm.sut.didDisappear()
        let group = ContinuationUIFixture(chrome: .group)
        group.vm.sut.didAppear()
        group.vm.sut.didTapContinue(taskID: "abc12345")
        #expect(group.vm.sut.continuationPresentation == nil && group.owner.startCount == 0)
        group.vm.sut.didDisappear()
    }

    @Test func givenPresentation_whenIdentityOrCheckFlagsChange_thenEqualityAndReportedStatusRemainPrecise() {
        // given
        let first = TaskContinuationPresentation(taskID: "full-A", phase: .unknown, attemptID: UUID(), status: .failed, locksActions: true)
        var changed = first
        // when / then
        changed.attemptID = UUID()
        #expect(first != changed)
        changed = first; changed.isChecking = true
        #expect(first != changed)
        changed = first; changed.message = "Engine reason"
        #expect(first != changed)
        #expect(first.status == .failed && first.title == "A new session may have started")
    }
}
