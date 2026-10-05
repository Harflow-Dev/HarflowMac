import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - EventStreamRepositoryImpl

public final class EventStreamRepositoryImpl: EventStreamRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let snapshotRepository: any TaskSnapshotRepository
    private let scheduler: any Scheduling

    private let lock = NSRecursiveLock()
    private var streams: [String: TaskStream] = [:]

    /// `EventStreamRepository → TaskSnapshotRepository`, never the reverse (F6/decision 6).
    public init(toolEnvironment: any ToolEnvironmentRepository, snapshotRepository: any TaskSnapshotRepository, scheduler: any Scheduling) {
        self.toolEnvironment = toolEnvironment
        self.snapshotRepository = snapshotRepository
        self.scheduler = scheduler
    }

    public func acquire(_ taskID: String) -> any EventStreamLease { acquire(taskID, activity: true) }
    public func acquireSummary(_ taskID: String) -> any EventStreamLease { acquire(taskID, activity: false) }
    private func acquire(_ taskID: String, activity: Bool) -> any EventStreamLease {
        lock.lock()
        let stream: TaskStream
        let isFirst: Bool
        if let existing = streams[taskID] {
            stream = existing
            stream.refCount += 1
            isFirst = false
        } else {
            let path = TaskTitle.eventsPath(tasksDirectory: toolEnvironment.tasksDirectory, taskID: taskID) ?? "/dev/null"
            stream = TaskStream(taskID: taskID, path: path, scheduler: scheduler)
            stream.refCount = 1
            streams[taskID] = stream
            isFirst = true
        }
        let startActivity = activity && stream.activityRefCount == 0
        if activity { stream.activityRefCount += 1 }
        if startActivity { stream.start() }
        lock.unlock()
        if isFirst {
            stream.startSummary()
        }
        if startActivity { Task { [snapshotRepository] in await snapshotRepository.refresh(taskID) } }
        return EventStreamLeaseImpl(taskID: taskID, repository: self, activity: activity)
    }

    fileprivate func releaseLease(for taskID: String, activity: Bool) {
        lock.lock()
        guard let stream = streams[taskID] else { lock.unlock(); return }
        stream.refCount -= 1
        if activity { stream.activityRefCount -= 1 }
        let stopActivity = activity && stream.activityRefCount <= 0
        let shouldStop = stream.refCount <= 0
        if shouldStop { streams[taskID] = nil }
        if stopActivity { stream.stopActivity() }
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

    public func loadMoreSummaryFiles(_ taskID: String) { stream(taskID)?.loadMoreSummaryFiles() }
    public func loadMore(_ taskID: String) { stream(taskID)?.loadMore() }
    public func history(for taskID: String) -> EventHistoryState { stream(taskID)?.history ?? EventHistoryState() }
    public func historyPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never> {
        stream(taskID)?.$history.eraseToAnyPublisher() ?? Just(EventHistoryState()).eraseToAnyPublisher()
    }

    public func summary(for taskID: String) -> EventSummary { stream(taskID)?.summary ?? EventSummary() }
    public func summaryPublisher(for taskID: String) -> AnyPublisher<EventSummary, Never> {
        stream(taskID)?.$summary.eraseToAnyPublisher() ?? Just(EventSummary()).eraseToAnyPublisher()
    }

    public func current(for taskID: String) -> TimelineItem? { Timeline.current(in: items(for: taskID)) }
    public func activity(for taskID: String) -> ActivityCounts { summary(for: taskID).activity }
    public func prompt(for taskID: String) -> String? { summary(for: taskID).prompt }

    public var leasedTaskIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(streams.filter { $0.value.activityRefCount > 0 }.map(\.key))
    }
}

// MARK: - TaskStream

/// One task's live events, tailed while at least one lease is outstanding. `apply` runs
/// synchronously on whatever queue the tailer calls back on (the main queue — `Tail.swift:187`),
/// under `@Subjected`'s own lock, so resets and appends can never interleave out of order.
private final class TaskStream: @unchecked Sendable {
    /// Review round 1, item 4: a burst of `assistant_delta`-only callbacks is batched for up to this
    /// long before the timeline is rebuilt and published, rather than once per delta. Chosen as the
    /// midpoint of the settled 50–100 ms window.
    static let coalesceWindow: TimeInterval = 0.075

    let taskID: String
    let path: String
    let scheduler: any Scheduling
    @Subjected var history = EventHistoryState(isLoading: true)
    @Subjected var summary = EventSummary()
    private let summaryQueue = DispatchQueue(label: "dev.polybridge.monitor.summary")
    private var summaryStopped = false
    private var summaryFileLimit = 100
    private var lastSummaryPublish = Date.distantPast
    private var summaryBuilder = EventSummaryBuilder()
    @Subjected var events: [TaskEvent] = []
    @Subjected var items: [TimelineItem] = []
    @Subjected var eventsAvailability: EventAvailability = .loading
    var refCount = 0
    var activityRefCount = 0
    private var tailer: EventFileTailer?
    /// Codex review round 1 on Monitor piece 8's performance: `Timeline.items(from: next)` used to
    /// rebuild the WHOLE timeline from the whole history on every flush — O(n²) total over a long
    /// stream. Kept across flushes and appended to with only that flush's own new events; replaced
    /// outright (never told to "forget") on a tailer reset.
    private var timelineBuilder = TimelineBuilder()

    /// One buffered tailer callback, applied in arrival order by `applyPending()` — preserved as a
    /// queue (not merged eagerly) so a `reset` batch still clears exactly what came before it and
    /// nothing after, even though several callbacks may be sitting in the buffer at once.
    private struct PendingBatch {
        let events: [TaskEvent]
        let reset: Bool
    }

    private let bufferLock = NSLock()
    private var pendingBatches: [PendingBatch] = []
    private var pendingAvailability: EventAvailability?
    private var flushToken: AnyCancellable?

    init(taskID: String, path: String, scheduler: any Scheduling) {
        self.taskID = taskID
        self.path = path
        self.scheduler = scheduler
    }

    func start() {
        let tailer = EventFileTailer(path: path, historyHandler: { [weak self] in self?.history = $0 }) { [weak self] newEvents, reset, availability in
            self?.enqueue(newEvents, reset: reset, availability: availability)
        }
        tailer.start()
        self.tailer = tailer
    }

    func loadMore() { tailer?.loadMore() }
    func loadMoreSummaryFiles() {
        summaryQueue.async { [weak self] in
            guard let self else { return }
            summaryFileLimit += 100
            summary = summaryBuilder.snapshot(fileLimit: summaryFileLimit)
        }
    }

    func startSummary() {
        summaryQueue.async { [weak self] in self?.readSummary(tail: LineTail(maxChunk: 64 << 10)) }
    }

    private func readSummary(tail initial: LineTail) {
        guard !summaryStopped else { return }
        var tail = initial
        tail.maxLines = EventPages.pageSize
        guard let step = tail.read(path: path) else {
            summaryBuilder.setAvailability(.unavailable)
            summary = summaryBuilder.summary
            return
        }
        if step.reset { summaryBuilder = EventSummaryBuilder() }
        summaryBuilder.append(step.lines.compactMap(TaskEvent.init(line:)))
        summaryBuilder.setAvailability(step.more ? .loading : .available)
        if !step.more || Date().timeIntervalSince(lastSummaryPublish) >= 0.1 {
            summary = summaryBuilder.snapshot(fileLimit: summaryFileLimit)
            lastSummaryPublish = Date()
        }
        if step.more {
            summaryQueue.async { [weak self] in self?.readSummary(tail: tail) }
        } else {
            summaryQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.readSummary(tail: tail) }
        }
    }

    func stopActivity() { tailer?.stop(); tailer = nil }

    func stop() {
        summaryQueue.async { [weak self] in self?.summaryStopped = true }
        tailer?.stop()
        tailer = nil
        bufferLock.lock()
        flushToken?.cancel()
        flushToken = nil
        pendingBatches = []
        pendingAvailability = nil
        bufferLock.unlock()
    }

    /// A callback made up entirely of `assistant_delta` events (no reset, at least one event) is
    /// buffered behind a debounce timer rather than applied at once — the timeline is rebuilt only
    /// when that timer fires. Anything else (a reset, a mix of kinds, `task_finished`, or an
    /// availability-only callback with no new events) flushes immediately, taking whatever deltas
    /// were already buffered with it — this is the "final flush on terminal" half of the design; the
    /// debounce timer itself is the "final flush on idle" half, since it fires on a fixed schedule
    /// regardless of whether the stream keeps producing deltas.
    private func enqueue(_ newEvents: [TaskEvent], reset: Bool, availability: EventAvailability) {
        let isPureDeltaBurst = !reset && !newEvents.isEmpty && newEvents.allSatisfy(\.isAssistantDelta)
        bufferLock.lock()
        pendingBatches.append(PendingBatch(events: newEvents, reset: reset))
        pendingAvailability = availability
        if isPureDeltaBurst {
            if flushToken == nil {
                flushToken = scheduler.schedule(after: Self.coalesceWindow) { [weak self] in
                    self?.applyPending()
                }
            }
            bufferLock.unlock()
            return
        }
        flushToken?.cancel()
        flushToken = nil
        bufferLock.unlock()
        applyPending()
    }

    /// Held for the whole apply, not just the buffer drain: an immediate flush (the tailer's own
    /// queue) and a debounced one (the scheduler's own queue, a *different* queue for
    /// `SystemScheduler`) can otherwise race each other's read-modify-write of `events`, each
    /// computing `next` from a stale read and one's update silently overwriting the other's. Serial
    /// application under one lock is what actually gives "the timeline is rebuilt at most once per
    /// window" its ordering guarantee, not just the buffer bookkeeping.
    private func applyPending() {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let batches = pendingBatches
        let availability = pendingAvailability
        pendingBatches = []
        pendingAvailability = nil
        flushToken = nil
        guard !batches.isEmpty else { return }
        var next = events
        for batch in batches {
            if batch.reset {
                next = []
                timelineBuilder = TimelineBuilder()
            }
            // Unknown kinds are kept for Raw events but never shown on the timeline (F4-27).
            let known = Set(next.map(\.seq))
            let additions = batch.events.filter { !known.contains($0.seq) }
            let prepend = additions.first.map { first in next.first.map { first.seq < $0.seq } ?? false } ?? false
            next.append(contentsOf: additions)
            if prepend { next.sort { $0.seq < $1.seq }; timelineBuilder = TimelineBuilder(); timelineBuilder.append(next) }
            // Only THIS batch's own new events — never `next`, the whole accumulated history — is
            // what makes this incremental (Codex review round 1, finding 1).
            if !prepend { timelineBuilder.append(additions) }
        }
        events = next
        items = timelineBuilder.items
        if let availability { eventsAvailability = availability }
    }
}

extension TaskEvent {
    fileprivate var isAssistantDelta: Bool {
        if case .assistantDelta = kind { return true }
        return false
    }
}

// MARK: - EventStreamLeaseImpl

private final class EventStreamLeaseImpl: EventStreamLease, @unchecked Sendable {
    let taskID: String
    private weak var repository: EventStreamRepositoryImpl?
    private let lock = NSLock()
    private var released = false
    private let activity: Bool

    init(taskID: String, repository: EventStreamRepositoryImpl, activity: Bool) {
        self.taskID = taskID
        self.repository = repository
        self.activity = activity
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        repository?.releaseLease(for: taskID, activity: activity)
    }

    deinit {
        release()
    }
}
