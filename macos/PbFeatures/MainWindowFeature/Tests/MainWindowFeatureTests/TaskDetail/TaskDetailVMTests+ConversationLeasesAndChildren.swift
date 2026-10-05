import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import Testing

/// Split out of `TaskDetailVMTests+Conversation.swift` purely to keep that file under the swiftlint
/// length budget — same harness (`makeConversationSUT`/`conversationTask`/`ConversationSUT`, made
/// non-`private` there for this), same behaviour. Covers per-member event leases and the shared
/// `LineageIndex` batching (Codex review round 1, finding 1).
@MainActor
extension TaskDetailVMTests {

    // MARK: - Leases: one per member, acquired/released, a new member is picked up

    @Test func givenAConversationOfTwo_whenAppearing_thenOlderActivityWaitsForLoadMore() async {
        // given
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB])
        await waitUntil { harness.sut.task != nil }

        // then
        verify(harness.useCase).acquireEventLease(.value("a")).called(0)
        #expect(harness.sut.timelineModel.history.hasMore)
        harness.sut.timelineModel.onLoadMore?()
        verify(harness.useCase).acquireEventLease(.value("a")).called(1)
        verify(harness.useCase).acquireEventLease(.value("b")).called(1)

        // when
        harness.sut.didDisappear()

        // then — both leases release (idempotent `release()` stub tolerates either order).
        verify(harness.useCase).acquireEventLease(.value("a")).called(1)
        verify(harness.useCase).acquireEventLease(.value("b")).called(1)
    }

    @Test func givenAFollowUpArrivesAfterAppear_whenTheListingUpdates_thenTheNewMemberGetsItsOwnLeaseImmediately() async {
        // given — starts as a single-member conversation, "a"; "b" (its future follow-up) is
        // pre-stubbed but not yet a member, so its lease truly is acquired only once it appears.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA], stubbedMembers: [taskA, taskB])
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA])
        await waitUntil { harness.sut.task != nil }
        verify(harness.useCase).acquireEventLease(.value("b")).called(0)

        // when — "b" appears as a follow-up (a resume of "a").
        harness.membersBox.value = [taskA, taskB]
        harness.tasksSubject.send([taskA, taskB])

        // then
        await waitUntil { harness.sut.task?.taskID == "b" }
        verify(harness.useCase).acquireEventLease(.value("b")).called(1)
    }

    // MARK: - One shared LineageIndex per recompute (Codex review round 1, finding 1)

    @Test func givenAThreeMemberConversation_whenRecomputed_thenChildrenAreFetchedInOneCallNotOnePerMember() async {
        // given — three members, each with its own children, so a per-member loop would call
        // `children(of:)` three times; the fix is ONE `children(ofEach:)` call answering all three.
        let taskA = conversationTask("a", status: "completed", minute: 0)
        let taskB = conversationTask("b", status: "completed", parentTaskID: "a", minute: 1)
        let taskC = conversationTask("c", status: "running", parentTaskID: "b", minute: 2)
        let harness = makeConversationSUT(openedAs: "a", initialMembers: [taskA, taskB, taskC])
        harness.childrenBox["a"]?.value = [conversationTask("a-child", spawnedBy: "a")]
        harness.childrenBox["c"]?.value = [conversationTask("c-child", spawnedBy: "c")]
        harness.sut.didAppear()
        harness.tasksSubject.send([taskA, taskB, taskC])
        await waitUntil { harness.sut.timelineModel.subTaskStrip != nil }

        // then — the batched answer already reached the VM correctly (both members' children show,
        // conversation-member order preserved), and the per-id `children(of:)` (which would each
        // rebuild the index from scratch) is never called at all, however many recomputes ran during
        // setup.
        #expect(harness.sut.timelineModel.subTaskStrip?.children.map(\.task.taskID) == ["a-child", "c-child"])
        verify(harness.useCase).children(of: .any).called(0)
        // Let every still-pending setup-time recompute (this harness's `Just` publishers each fire
        // once on subscription, asynchronously) actually run before taking the baseline — otherwise
        // "one more call" would count some of that leftover noise as the deliberate recompute below.
        await waitUntil(timeout: 0.2) { false }

        // when — one further, deliberate recompute (a real content change, so `.removeDuplicates()`
        // on the tasks stream never suppresses it).
        let before = harness.childrenOfEachCallCount.value
        let taskCFinished = conversationTask("c", status: "completed", parentTaskID: "b", minute: 2)
        harness.membersBox.value = [taskA, taskB, taskCFinished]
        harness.tasksSubject.send([taskA, taskB, taskCFinished])
        await waitUntil { harness.sut.task?.status.isRunning == false }

        // then — exactly one MORE call for that one recompute, not one per member (three).
        #expect(harness.childrenOfEachCallCount.value == before + 1)
        verify(harness.useCase).children(of: .any).called(0)
    }
}
