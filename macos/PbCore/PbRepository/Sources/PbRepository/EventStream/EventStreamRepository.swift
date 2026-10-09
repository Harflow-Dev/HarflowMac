import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - EventStreamLease

/// A token for one caller's interest in a task's live event stream. Releases itself on `deinit`;
/// `release()` is idempotent and safe to call more than once (matches the VM `didAppear`/
/// `didDisappear` teardown rule — see the root AGENTS.md's "Teardown rule").
@Mockable
public protocol EventStreamLease: AnyObject, Sendable {
    var taskID: String { get }
    func release()
}

// MARK: - EventStreamRepository

/// Ref-counted, per-task event tailing shared across every screen watching the same task at once
/// (the menu bar, TaskDetail, a Parallel column) — decision 6. One `EventFileTailer` per task,
/// however many leases are outstanding. The first lease on a task triggers
/// `TaskSnapshotRepository.refresh(id)` (F4-13); the last release stops the tailer. A missing events
/// path falls back to `/dev/null` (F4-13). Tailer callbacks are folded on a serial background queue in arrival order.
/// Completed history publishes only after its item snapshot; concurrent `loadMore` calls coalesce.
@Mockable
public protocol EventStreamRepository: Sendable {

    func acquireSummary(_ taskID: String) -> any EventStreamLease
    func loadMoreSummaryFiles(_ taskID: String)
    @discardableResult func loadMore(_ taskID: String) -> Bool
    func history(for taskID: String) -> EventHistoryState
    func historyPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never>
    func summary(for taskID: String) -> EventSummary
    func summaryPublisher(for taskID: String) -> AnyPublisher<EventSummary, Never>

    func acquire(_ taskID: String) -> any EventStreamLease

    func events(for taskID: String) -> [TaskEvent]
    func items(for taskID: String) -> [TimelineItem]
    func eventsPublisher(for taskID: String) -> AnyPublisher<[TaskEvent], Never>
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>

    /// Whether the task's event log could actually be read the last time it was tailed — `.loading`
    /// before any lease has been acquired or any read attempted. Lets a caller (the Summary tab's
    /// "Files the agent edited" section) tell "nothing has happened yet" apart from "there is no log
    /// to read at all", which an empty `events(for:)` cannot do on its own.
    func eventsAvailability(for taskID: String) -> EventAvailability
    func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never>

    /// The latest tool call still waiting for its result — `Timeline.current`.
    func current(for taskID: String) -> TimelineItem?
    func activity(for taskID: String) -> ActivityCounts
    func prompt(for taskID: String) -> String?

    /// Every task id with at least one outstanding lease — what `TaskListRepository` refreshes
    /// snapshots for on every successful list (F6's structural requirement).
    var leasedTaskIDs: Set<String> { get }
}

public extension EventStreamRepository {
    func acquireSummary(_ id: String) -> any EventStreamLease { acquire(id) }
    func loadMoreSummaryFiles(_: String) {}
    @discardableResult func loadMore(_: String) -> Bool { false }
    func history(for _: String) -> EventHistoryState { EventHistoryState() }
    func historyPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { Just(history(for: id)).eraseToAnyPublisher() }
    func summary(for id: String) -> EventSummary {
        var builder = EventSummaryBuilder()
        builder.append(events(for: id))
        builder.setAvailability(eventsAvailability(for: id))
        return builder.summary
    }

    func summaryPublisher(for id: String) -> AnyPublisher<EventSummary, Never> { Just(summary(for: id)).eraseToAnyPublisher() }
}

// MARK: - NullEventStreamLease

final class NullEventStreamLease: EventStreamLease {
    let taskID: String
    init(taskID: String) { self.taskID = taskID }
    func release() {}
}

// MARK: - NullEventStreamRepository

public struct NullEventStreamRepository: EventStreamRepository {
    public init() {}
    public func acquire(_ taskID: String) -> any EventStreamLease { NullEventStreamLease(taskID: taskID) }
    public func events(for _: String) -> [TaskEvent] { [] }
    public func items(for _: String) -> [TimelineItem] { [] }
    public func eventsPublisher(for _: String) -> AnyPublisher<[TaskEvent], Never> { Just([]).eraseToAnyPublisher() }
    public func itemsPublisher(for _: String) -> AnyPublisher<[TimelineItem], Never> { Just([]).eraseToAnyPublisher() }
    public func eventsAvailability(for _: String) -> EventAvailability { .unavailable }
    public func eventsAvailabilityPublisher(for _: String) -> AnyPublisher<EventAvailability, Never> {
        Just(.unavailable).eraseToAnyPublisher()
    }

    public func current(for _: String) -> TimelineItem? { nil }
    public func activity(for _: String) -> ActivityCounts { ActivityCounts() }
    public func prompt(for _: String) -> String? { nil }
    public var leasedTaskIDs: Set<String> { [] }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global event-stream repository.
    @GlobalEntry var eventStreamRepository: any EventStreamRepository = NullEventStreamRepository()
}
