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
/// path falls back to `/dev/null` (F4-13). Tailer callbacks are applied synchronously, in arrival
/// order, under the per-task `@Subjected` lock — never as one `Task` per callback, which could
/// reorder a reset ahead of an append.
@Mockable
public protocol EventStreamRepository: Sendable {

    func acquire(_ taskID: String) -> any EventStreamLease

    func events(for taskID: String) -> [TaskEvent]
    func items(for taskID: String) -> [TimelineItem]
    func eventsPublisher(for taskID: String) -> AnyPublisher<[TaskEvent], Never>
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>

    /// The latest tool call still waiting for its result — `Timeline.current`.
    func current(for taskID: String) -> TimelineItem?
    func activity(for taskID: String) -> ActivityCounts
    func prompt(for taskID: String) -> String?

    /// Every task id with at least one outstanding lease — what `TaskListRepository` refreshes
    /// snapshots for on every successful list (F6's structural requirement).
    var leasedTaskIDs: Set<String> { get }
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
