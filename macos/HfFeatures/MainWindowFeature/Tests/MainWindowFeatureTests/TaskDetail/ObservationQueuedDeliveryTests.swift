import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
extension TaskDetailVMTests {
    @Test func givenAcceptedOldFrameQueuedOnMain_whenRepositoryBindingChangesBeforeDelivery_thenOldRowsNeverReplaceCurrentWindow() async {
        // given
        let harness = makeSUT()
        let member = task(status: "completed")
        harness.detailBox.value = member
        let initial = FeatureObservationFixture.frame(id: member.taskID)
        harness.observationBox.value = initial
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.observationFrames[member.taskID] == initial }
        let old = EventObservationFrame(taskID: member.taskID, scope: initial.scope, revision: 1,
            items: [PreviewFixtures.textItem("Old binding content", seq: 7)], history: .init(caughtUp: true))
        let fresh = EventObservationFrame(taskID: member.taskID,
            scope: EventObservationScope(sessionID: UUID(), sourceID: UUID(), windowID: UUID()))
        // when — send is synchronous; receive(on:) queues delivery until this actor yields.
        harness.observationBox.value = old
        harness.observationSubject.send(old)
        harness.observationBox.value = fresh
        await drainMainObservationQueue()
        // then
        #expect(harness.sut.observationFrames[member.taskID] == initial)
        #expect(harness.sut.itemsByMember[member.taskID]?.isEmpty == true)
        harness.observationSubject.send(fresh)
        await waitUntil { harness.sut.observationFrames[member.taskID] == fresh }
        #expect(harness.sut.observationFrames[member.taskID] == fresh)
        harness.sut.didDisappear()
    }

    @Test func givenMultiTurnConversation_whenOpened_thenStoredRequestUsesFirstMemberAndRecoveryUsesCurrentMember() async {
        // given
        let first = conversationTask("original", minute: 0)
        let current = conversationTask("current", parentTaskID: "original", minute: 1)
        let harness = makeConversationSUT(openedAs: "current", initialMembers: [first, current])
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([first, current])
        await waitUntil { harness.sut.requestTaskID != nil && harness.sut.recoveryTaskID != nil }
        // then
        #expect(harness.sut.requestTaskID == first.taskID)
        #expect(harness.sut.recoveryTaskID == current.taskID)
        verify(harness.useCase).readRequest(for: .value(first.taskID), maxBytes: .value(65536)).called(1)
        verify(harness.useCase).readRequest(for: .value(current.taskID), maxBytes: .any).called(0)
        verify(harness.useCase).recoveredTranscript(for: .value(current.taskID)).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenOldRequestAndRecoveryQueued_whenCurrentGettersClearBeforeDelivery_thenStaleTextIsRejected() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task()
        harness.sut.didAppear()
        harness.tasksSubject.send([task()])
        await waitUntil { harness.sut.requestTaskID != nil }
        let oldRequest = TaskRequestReadState.loading(maxBytes: 131072)
        let oldRecovery = RecoveredTranscriptFrame(generation: UUID(), items: [PreviewFixtures.textItem("old recovered text", seq: 7)])
        // when
        harness.requestBox.value = oldRequest
        harness.recoveryBox.value = oldRecovery
        harness.requestSubject.send(oldRequest)
        harness.recoverySubject.send(oldRecovery)
        harness.requestBox.value = .notRequested
        harness.recoveryBox.value = .init()
        await drainMainObservationQueue()
        // then
        #expect(harness.sut.requestReadState == .notRequested)
        #expect(harness.sut.recoveredTranscript == .init())
        harness.sut.didDisappear()
    }
}

@MainActor
extension ParallelVMTests {
    @Test func givenOldColumnFrameQueued_whenGetterMovesToFreshContentBeforeDelivery_thenOldRowsAreRejected() async {
        // given
        let harness = makeSUT()
        let member = task(id: "queued-column")
        let subject = PassthroughSubject<[TimelineItem], Never>()
        harness.itemSubjectsBox.value[member.taskID] = subject
        harness.tasksBox.value[member.taskID] = member
        harness.availabilityBox.value[member.taskID] = .available
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let initial = harness.sut.observationFrames[member.taskID]
        // when
        subject.send([PreviewFixtures.textItem("queued stale content", seq: 7)])
        harness.itemsBox.value[member.taskID] = [PreviewFixtures.textItem("current getter content", seq: 6)]
        await drainMainObservationQueue()
        // then
        #expect(harness.sut.observationFrames[member.taskID] == initial)
        #expect(harness.sut.columns.first?.rows.isEmpty == true)
        harness.sut.didDisappear()
    }
}

/// A FIFO sentinel after receive(on: main) jobs makes rejection assertions deterministic.
@MainActor
private func drainMainObservationQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
