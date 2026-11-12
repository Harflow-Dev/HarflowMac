import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

extension ParallelVMTests {
    @Test func givenReleasedWindowReacquiredWithNewScope_whenPreparingColumn_thenCachedRowsRequireExplicitAdoption() throws {
        // given — viewport release retains the last presentation; reacquisition starts a new local scope.
        let memberTask = task(id: "retained", status: "completed")
        let old = FeatureObservationFixture.frame(id: memberTask.taskID,
            items: [PreviewFixtures.textItem("Retained row", seq: 7)], availability: .available)
        let freshScope = EventObservationScope(sessionID: UUID(), sourceID: UUID(), windowID: UUID())
        let fresh = EventObservationFrame(taskID: memberTask.taskID, scope: freshScope,
            items: [PreviewFixtures.textItem("New source row", seq: 6)], history: .init(caughtUp: true))
        let member = ParallelMemberInput(task: memberTask, items: old.items, prompt: nil, availability: .available, observation: old)
        let base = ParallelColumnPresentation(id: memberTask.id, task: memberTask, title: "Retained", subtitle: memberTask.backend,
            isBusy: false, outcomeMessage: nil, showPrompt: false, start: nil, memberTaskIDs: [memberTask.id])
        let previous = ParallelColumnInput(base: base, members: [member], events: [], snapshot: nil)
        let adoption = ParallelWindowAdoption()
        // when
        #expect(adoption.needsAdoption(id: memberTask.id, previous: previous, frames: [memberTask.id: fresh]))
        let presentation = try ParallelPresentationBuilder.build(previous)
        var column = ParallelColumnModel(id: memberTask.id, task: memberTask, title: "Retained", subtitle: memberTask.backend,
            isBusy: false, outcomeMessage: nil, showPrompt: false, rows: presentation.rows,
            activityRows: presentation.activityRows, liveStep: presentation.liveStep, isLoading: false,
            summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        let retainedIDs = column.rows.map(\.id)
        var requested = false
        adoption.prepareColumn(&column, id: memberTask.id) { requested = true }
        // then
        #expect(column.rows.map(\.id) == retainedIDs)
        #expect(column.cachedHistoryNotice != nil)
        #expect(column.noToolCallsText == nil && column.stepCountText == nil && column.liveStep == nil)
        #expect(column.onAdoptWindow != nil)
        column.onAdoptWindow?()
        #expect(requested)
        adoption.adopt(id: memberTask.id, frames: [memberTask.id: fresh], members: [memberTask.id])
        #expect(!adoption.needsAdoption(id: memberTask.id, previous: previous, frames: [memberTask.id: fresh]))
        #expect(adoption.pending.isEmpty)
    }

    @Test(arguments: [EventObservationReason.resetExhausted, .historicalLimit])
    func givenSourceChangeWithoutReadAuthority_whenColumnPrepared_thenRecoveryLimitHasNoAdoptionAction(reason: EventObservationReason) throws {
        // given
        let memberTask = task(id: "limited", status: "completed")
        let old = FeatureObservationFixture.frame(id: memberTask.id,
            items: [PreviewFixtures.textItem("Cached evidence", seq: 7)], availability: .available)
        let member = ParallelMemberInput(task: memberTask, items: old.items, prompt: nil, availability: .available, observation: old)
        let base = ParallelColumnPresentation(id: memberTask.id, task: memberTask, title: "Limited", subtitle: memberTask.backend,
            isBusy: false, outcomeMessage: nil, showPrompt: false, start: nil, memberTaskIDs: [memberTask.id])
        let previous = ParallelColumnInput(base: base, members: [member], events: [], snapshot: nil)
        let unavailable = EventObservationFrame(taskID: memberTask.id, scope: old.scope, items: old.items,
            history: .init(reasons: [reason], currentness: .sourceChangePending))
        let adoption = ParallelWindowAdoption()
        var column = ParallelColumnModel(id: memberTask.id, task: memberTask, title: "Limited", subtitle: memberTask.backend,
            isBusy: false, outcomeMessage: nil, showPrompt: false, rows: [], activityRows: [], liveStep: nil,
            isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        // when
        #expect(adoption.needsAdoption(id: memberTask.id, previous: previous, frames: [memberTask.id: unavailable]))
        var requested = false
        adoption.prepareColumn(&column, id: memberTask.id) { requested = true }
        // then
        #expect(column.cachedHistoryNotice?.contains("recovery limit") == true)
        #expect(column.onAdoptWindow == nil)
        column.onAdoptWindow?()
        #expect(!requested)
        #expect(adoption.pending == [memberTask.id])
        // A subsequently offered public action restores the explicit affordance.
        let offered = EventObservationFrame(taskID: memberTask.id, scope: old.scope, items: old.items,
            history: .init(currentness: .sourceChangePending, availableActions: [.adoptCurrentSource]))
        #expect(adoption.needsAdoption(id: memberTask.id, previous: previous, frames: [memberTask.id: offered]))
        adoption.prepareColumn(&column, id: memberTask.id) { requested = true }
        #expect(column.onAdoptWindow != nil)
    }

    @Test func givenStaleAdoptionClosureAfterRecoveryLimit_whenInvoked_thenNoReadOrLocalAdoptionOccurs() async {
        // given
        let harness = makeSUT()
        let member = task(id: "stale-adoption", status: "completed")
        harness.tasksBox.value[member.id] = member
        harness.availabilityBox.value[member.id] = .available
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let staleAction = { harness.sut.adoptObservationWindow(member.id) }
        let blocked = EventObservationFrame(taskID: member.id, scope: FeatureObservationFixture.scope,
            history: .init(reasons: [.resetExhausted], currentness: .sourceChangePending))
        harness.sut.observationFrames[member.id] = blocked
        harness.sut.refreshingRetainedIDs.insert(member.id)
        // when
        staleAction()
        // then
        #expect(harness.sut.refreshingRetainedIDs.contains(member.id), "stale callback cannot locally accept an unavailable replacement")
        #expect(harness.sut.observationFrames[member.id] == blocked)
        verify(harness.useCase).requestObservation(.any, for: .any, scope: .any).called(0)
        #expect(harness.loadCallsBox.value.isEmpty)
        harness.sut.didDisappear()
    }

    @Test func givenCapacityWithSoundSummary_whenExplicitReplacementRequested_thenScopedRebaseKeepsFactsAndRetainedWindowUntilNewScope() async throws {
        // given
        let harness = makeSUT()
        let member = task(id: "capacity", status: "completed")
        let subject = PassthroughSubject<[TimelineItem], Never>()
        harness.tasksBox.value[member.id] = member
        harness.itemsBox.value[member.id] = [PreviewFixtures.textItem("Retained capacity row", seq: 7)]
        harness.itemSubjectsBox.value[member.id] = subject
        harness.availabilityBox.value[member.id] = .available
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let retained = try #require(harness.sut.columns.first?.rows)
        var counts = ActivityCounts()
        counts.toolCalls = 2
        let capacity = EventObservationFrame(taskID: member.id, scope: FeatureObservationFixture.scope,
            items: harness.itemsBox.value[member.id] ?? [],
            history: .init(reasons: [.capacity], availableActions: [.rebaseWindow]),
            summary: .init(state: .observed, counts: counts, totalFiles: 0))
        harness.observationBox.value[member.id] = capacity
        subject.send(capacity.items)
        await waitUntil { harness.sut.columns.first?.onAdoptWindow != nil && harness.sut.isPresentationSettled }
        // when
        #expect(harness.sut.columns.first?.cachedHistoryNotice?.contains("activity limit") == true)
        harness.sut.columns.first?.onAdoptWindow?()
        // then
        verify(harness.useCase).requestObservation(.value(.rebaseWindow), for: .value(member.id), scope: .value(capacity.scope)).called(1)
        #expect(harness.sut.columns.first?.rows == retained)
        #expect(harness.sut.observationFrames[member.id]?.summary.counts?.toolCalls == 2)
        let scope = EventObservationScope(sessionID: capacity.scope.sessionID, sourceID: capacity.scope.sourceID, windowID: UUID())
        let replacement = EventObservationFrame(taskID: member.id, scope: scope, revision: 2,
            items: [PreviewFixtures.textItem("Accepted current window", seq: 6)], history: .init(caughtUp: true), summary: capacity.summary)
        harness.observationBox.value[member.id] = replacement
        subject.send(replacement.items)
        await waitUntil { harness.sut.columns.first?.cachedHistoryNotice == nil && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.first?.rows != retained)
        #expect(harness.sut.observationFrames[member.id]?.scope == scope)
        #expect(harness.sut.observationFrames[member.id]?.summary == capacity.summary)
        harness.sut.didDisappear()
    }

}
