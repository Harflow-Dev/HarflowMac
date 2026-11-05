import Combine
import Foundation
import MonitorCore

// MARK: - Legacy event stream projections

extension EventStreamRepositoryImpl {
    public func events(for taskID: String) -> [TaskEvent] { observation(for: taskID).events }
    public func items(for taskID: String) -> [TimelineItem] { observation(for: taskID).items }
    public func eventsPublisher(for taskID: String) -> AnyPublisher<[TaskEvent], Never> {
        observationPublisher(for: taskID).map(\.events).removeDuplicates().eraseToAnyPublisher()
    }

    public func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never> {
        observationPublisher(for: taskID).map(\.items).removeDuplicates().eraseToAnyPublisher()
    }

    public func eventsAvailability(for taskID: String) -> EventAvailability { Self.availability(observation(for: taskID)) }
    public func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never> {
        observationPublisher(for: taskID).map(Self.availability).removeDuplicates().eraseToAnyPublisher()
    }

    public func current(for taskID: String) -> TimelineItem? { Timeline.current(in: items(for: taskID)) }
    public func activity(for taskID: String) -> ActivityCounts { observation(for: taskID).summary.counts ?? ActivityCounts() }
    public func prompt(for _: String) -> String? { nil }
    public func loadMoreSummaryFiles(_: String) {} // Public summary files remain bounded to 100.
    @discardableResult public func loadMore(_ taskID: String) -> Bool {
        requestObservation(action: .loadEarlier, for: taskID, scope: observation(for: taskID).scope)
    }

    public func history(for taskID: String) -> EventHistoryState { Self.legacyHistory(observation(for: taskID)) }
    public func historyPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never> {
        observationPublisher(for: taskID).map(Self.legacyHistory).removeDuplicates().eraseToAnyPublisher()
    }

    public func summary(for taskID: String) -> EventSummary { Self.legacySummary(observation(for: taskID)) }
    public func summaryPublisher(for taskID: String) -> AnyPublisher<EventSummary, Never> {
        observationPublisher(for: taskID).map(Self.legacySummary).removeDuplicates().eraseToAnyPublisher()
    }

    private static func availability(_ frame: EventObservationFrame) -> EventAvailability {
        if frame.history.isLoading { return .loading }
        if frame.history.reasons.contains(.unavailable) || frame.history.currentness == .reconnecting { return .unavailable }
        return .available
    }

    private static func legacyHistory(_ frame: EventObservationFrame) -> EventHistoryState {
        EventHistoryState(hasMore: frame.history.hasOlder, isLoading: frame.history.isLoading,
                          error: frame.history.reasons.isEmpty ? nil : "Public event history is qualified; inspect observation coverage")
    }

    private static func legacySummary(_ frame: EventObservationFrame) -> EventSummary {
        var value = EventSummary()
        value.availability = frame.summary.state == .observed ? .available : frame.summary.state == .loading ? .loading : .unavailable
        value.files = frame.summary.files
        value.totalFiles = frame.summary.totalFiles ?? 0
        value.activity = frame.summary.counts ?? ActivityCounts()
        return value
    }
}
