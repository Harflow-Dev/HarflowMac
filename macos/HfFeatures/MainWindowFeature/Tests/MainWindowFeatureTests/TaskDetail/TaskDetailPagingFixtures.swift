import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
extension MockTaskDetailUseCase {
    func configurePagingDefaults(eventHistory: @escaping (String) -> EventHistoryState = { _ in EventHistoryState() },
                                 observationSubjects: [String: PassthroughSubject<EventObservationFrame, Never>] = [:],
                                 includeObservationDefaults: Bool = true) {
        if includeObservationDefaults {
        given(self).observation(for: .any).willProduce { [weak self] id in
            guard let self else { return FeatureObservationFixture.frame(id: id) }
            return FeatureObservationFixture.frame(id: id, events: events(for: id), items: items(for: id),
                availability: eventsAvailability(for: id), history: eventHistory(id))
        }
        given(self).observationPublisher(for: .any).willProduce { [weak self] id in
            guard let self else { return Empty().eraseToAnyPublisher() }
            if let subject = observationSubjects[id] {
                return subject.prepend(observation(for: id)).eraseToAnyPublisher()
            }
            return Publishers.Merge(
                itemsPublisher(for: id).map { [weak self] items in
                    FeatureObservationFixture.frame(id: id, events: self?.events(for: id) ?? [], items: items,
                        availability: self?.eventsAvailability(for: id) ?? .loading, history: eventHistory(id))
                },
                eventsAvailabilityPublisher(for: id).map { [weak self] availability in
                    FeatureObservationFixture.frame(id: id, events: self?.events(for: id) ?? [], items: self?.items(for: id) ?? [],
                        availability: availability, history: eventHistory(id))
                }
            )
.prepend(observation(for: id))
.eraseToAnyPublisher()
        }
        given(self).requestState(for: .any).willReturn(.notRequested)
        given(self).requestPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        given(self).recoveredTranscript(for: .any).willReturn(.init())
        given(self).recoveredTranscriptPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        }
        given(self).readRequest(for: .any, maxBytes: .any).willReturn()
        given(self).requestObservation(.any, for: .any, scope: .any).willProduce { [weak self] action, id, scope in
            guard action == .loadEarlier || action == .retryRead, scope == FeatureObservationFixture.scope else { return false }
            return self?.loadMoreEvents(id) ?? false
        }
        given(self).callerApprovalUseCase().willReturn(nil)
        given(self).resolveTask(.any).willReturn(nil)
        given(self).conversationHistory(sessionID: .any, cursor: .any).willReturn(nil)
        given(self).eventHistory(for: .any).willProduce(eventHistory)
        given(self).eventHistoryPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        given(self).eventSummary(for: .any).willProduce { [weak self] id in
            var builder = EventSummaryBuilder()
            builder.append(self?.events(for: id) ?? [])
            builder.setAvailability(self?.eventsAvailability(for: id) ?? .loading)
            return builder.summary
        }
        given(self).eventSummaryPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        given(self).acquireSummaryLease(.any).willProduce { id in
            let lease = MockEventStreamLease()
            given(lease).taskID.willReturn(id)
            given(lease).release().willReturn()
            return lease
        }
    }
}

/// Shared test-input adapter. Each publication contains rows and qualification from one snapshot.
/// Production never reconstructs public observation frames from these legacy event fixtures.
enum FeatureObservationFixture {
    static let scope = EventObservationScope(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        windowID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    static func frame(id: String, events: [TaskEvent] = [], items: [TimelineItem] = [],
                      availability: EventAvailability = .loading, history: EventHistoryState = .init()) -> EventObservationFrame {
        var summary = EventSummaryBuilder()
        summary.append(events)
        let loading = availability == .loading || history.isLoading
        let reasons: Set<EventObservationReason> = availability == .unavailable || history.error != nil ? [.unavailable] : []
        return EventObservationFrame(taskID: id, scope: scope, revision: history.generation,
            events: events, items: items,
            history: .init(isLoading: loading, hasOlder: history.hasMore, caughtUp: !loading && reasons.isEmpty,
                forwardDrained: !loading, reasons: reasons,
                availableActions: history.hasMore ? [.loadEarlier] : []),
            summary: .init(state: loading ? .loading : reasons.isEmpty ? .observed : .unavailable,
                counts: summary.summary.activity, files: summary.summary.files, totalFiles: summary.summary.totalFiles,
                reasons: reasons))
    }
}

@MainActor
extension TaskDetailVMTests {
    func publishObservations(_ harness: ConversationSUT) {
        for (id, subject) in harness.observationSubjects { subject.send(harness.useCase.observation(for: id)) }
    }

}

// MARK: - Exact execution detail

extension TaskDetailVMTests {
    @Test func givenWorkflowResumeChain_whenOlderChildOpened_thenShowsThatExecutionOnly() async throws {
        // given
        var oldRaw = conversationTask("old").raw
        oldRaw["workflow_run_id"] = .string("workflow")
        var nextRaw = conversationTask("next", parentTaskID: "old", minute: 1).raw
        nextRaw["workflow_run_id"] = .string("workflow")
        let old = try #require(TaskInfo(.object(oldRaw)))
        let next = try #require(TaskInfo(.object(nextRaw)))
        let harness = makeConversationSUT(openedAs: "old", initialMembers: [old, next])
        // when
        harness.sut.recomputeMembersAndLeases()
        // then
        #expect(harness.sut.conversationMembers.map(\.taskID) == ["old"])
        #expect(harness.sut.currentTaskID == "old")
    }
}
