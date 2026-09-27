import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - EventStreamRepositoryImpl

public final class EventStreamRepositoryImpl: EventStreamRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let snapshotRepository: any TaskSnapshotRepository

    private let lock = NSRecursiveLock()
    private var streams: [String: TaskStream] = [:]

    /// `EventStreamRepository → TaskSnapshotRepository`, never the reverse (F6/decision 6).
    public init(toolEnvironment: any ToolEnvironmentRepository, snapshotRepository: any TaskSnapshotRepository) {
        self.toolEnvironment = toolEnvironment
        self.snapshotRepository = snapshotRepository
    }

    public func acquire(_ taskID: String) -> any EventStreamLease {
        lock.lock()
        let stream: TaskStream
        let isFirst: Bool
        if let existing = streams[taskID] {
            stream = existing
            stream.refCount += 1
            isFirst = false
        } else {
            let path = TaskTitle.eventsPath(tasksDirectory: toolEnvironment.tasksDirectory, taskID: taskID) ?? "/dev/null"
            stream = TaskStream(taskID: taskID, path: path)
            stream.refCount = 1
            streams[taskID] = stream
            isFirst = true
        }
        lock.unlock()
        if isFirst {
            stream.start()
            Task { [snapshotRepository] in await snapshotRepository.refresh(taskID) }
        }
        return EventStreamLeaseImpl(taskID: taskID, repository: self)
    }

    fileprivate func releaseLease(for taskID: String) {
        lock.lock()
        guard let stream = streams[taskID] else { lock.unlock(); return }
        stream.refCount -= 1
        let shouldStop = stream.refCount <= 0
        if shouldStop { streams[taskID] = nil }
        lock.unlock()
        if shouldStop { stream.stop() }
    }

    private func stream(_ taskID: String) -> TaskStream? {
        lock.lock(); defer { lock.unlock() }
        return streams[taskID]
    }

    public func events(for taskID: String) -> [TaskEvent] { stream(taskID)?.events ?? [] }
    public func items(for taskID: String) -> [TimelineItem] { stream(taskID)?.items ?? [] }

    public func eventsPublisher(for taskID: String) -> AnyPublisher<[TaskEvent], Never> {
        guard let stream = stream(taskID) else { return Just([]).eraseToAnyPublisher() }
        return stream.$events.eraseToAnyPublisher()
    }

    public func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never> {
        guard let stream = stream(taskID) else { return Just([]).eraseToAnyPublisher() }
        return stream.$items.eraseToAnyPublisher()
    }

    public func eventsAvailability(for taskID: String) -> EventAvailability { stream(taskID)?.eventsAvailability ?? .loading }

    public func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never> {
        guard let stream = stream(taskID) else { return Just(.loading).eraseToAnyPublisher() }
        return stream.$eventsAvailability.eraseToAnyPublisher()
    }

    public func current(for taskID: String) -> TimelineItem? { Timeline.current(in: items(for: taskID)) }
    public func activity(for taskID: String) -> ActivityCounts { Timeline.activity(from: events(for: taskID)) }
    public func prompt(for taskID: String) -> String? { Timeline.prompt(in: events(for: taskID)) }

    public var leasedTaskIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(streams.keys)
    }
}

// MARK: - TaskStream

/// One task's live events, tailed while at least one lease is outstanding. `apply` runs
/// synchronously on whatever queue the tailer calls back on (the main queue — `Tail.swift:187`),
/// under `@Subjected`'s own lock, so resets and appends can never interleave out of order.
private final class TaskStream: @unchecked Sendable {
    let taskID: String
    let path: String
    @Subjected var events: [TaskEvent] = []
    @Subjected var items: [TimelineItem] = []
    @Subjected var eventsAvailability: EventAvailability = .loading
    var refCount = 0
    private var tailer: EventFileTailer?

    init(taskID: String, path: String) {
        self.taskID = taskID
        self.path = path
    }

    func start() {
        let tailer = EventFileTailer(path: path) { [weak self] newEvents, reset, availability in
            guard let self else { return }
            // One assignment per callback: subscribers receive on main asynchronously, so a separate
            // `events = []` would be delivered, and could render, as a transient empty timeline.
            var next = reset ? [] : events
            // Unknown kinds are kept for Raw events but never shown on the timeline (F4-27).
            next.append(contentsOf: newEvents)
            events = next
            items = Timeline.items(from: next)
            eventsAvailability = availability
        }
        tailer.start()
        self.tailer = tailer
    }

    func stop() {
        tailer?.stop()
        tailer = nil
    }
}

// MARK: - EventStreamLeaseImpl

private final class EventStreamLeaseImpl: EventStreamLease, @unchecked Sendable {
    let taskID: String
    private weak var repository: EventStreamRepositoryImpl?
    private let lock = NSLock()
    private var released = false

    init(taskID: String, repository: EventStreamRepositoryImpl) {
        self.taskID = taskID
        self.repository = repository
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        repository?.releaseLease(for: taskID)
    }

    deinit {
        release()
    }
}
