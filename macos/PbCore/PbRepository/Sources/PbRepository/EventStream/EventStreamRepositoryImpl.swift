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
    private let initialLoads: EventInitialLoadQueue

    /// `EventStreamRepository → TaskSnapshotRepository`, never the reverse (F6/decision 6).
    public convenience init(toolEnvironment: any ToolEnvironmentRepository, snapshotRepository: any TaskSnapshotRepository, scheduler: any Scheduling) {
        self.init(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: scheduler, initialLoads: EventInitialLoadQueue())
    }

    init(toolEnvironment: any ToolEnvironmentRepository, snapshotRepository: any TaskSnapshotRepository,
         scheduler: any Scheduling, initialLoads: EventInitialLoadQueue) {
        self.toolEnvironment = toolEnvironment
        self.snapshotRepository = snapshotRepository
        self.scheduler = scheduler
        self.initialLoads = initialLoads
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
            stream = TaskStream(taskID: taskID, path: path, scheduler: scheduler, initialLoads: initialLoads)
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
        return stream.$events.removeDuplicates().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    public func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never> {
        guard let stream = stream(taskID) else { return Just([]).eraseToAnyPublisher() }
        return stream.$items.removeDuplicates().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    public func eventsAvailability(for taskID: String) -> EventAvailability { stream(taskID)?.eventsAvailability ?? .loading }

    public func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never> {
        guard let stream = stream(taskID) else { return Just(.loading).eraseToAnyPublisher() }
        return stream.$eventsAvailability.removeDuplicates().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    public func loadMoreSummaryFiles(_ taskID: String) { stream(taskID)?.loadMoreSummaryFiles() }
    @discardableResult public func loadMore(_ taskID: String) -> Bool { stream(taskID)?.loadMore() ?? false }
    public func history(for taskID: String) -> EventHistoryState { stream(taskID)?.history ?? EventHistoryState() }
    public func historyPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never> {
        stream(taskID)?.$history.removeDuplicates().receive(on: DispatchQueue.main).eraseToAnyPublisher() ?? Just(EventHistoryState()).eraseToAnyPublisher()
    }

    public func summary(for taskID: String) -> EventSummary { stream(taskID)?.summary ?? EventSummary() }
    public func summaryPublisher(for taskID: String) -> AnyPublisher<EventSummary, Never> {
        stream(taskID)?.$summary.removeDuplicates().eraseToAnyPublisher() ?? Just(EventSummary()).eraseToAnyPublisher()
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

/// One task's live events, folded on a serial utility queue while activity leases exist.
/// Tailer callbacks enqueue in arrival order; completed history publishes after folded items.
private final class TaskStream: @unchecked Sendable {
    /// Review round 1, item 4: a burst of `assistant_delta`-only callbacks is batched for up to this
    /// long before the timeline is rebuilt and published, rather than once per delta. Chosen as the
    /// midpoint of the settled 50–100 ms window.
    static let coalesceWindow: TimeInterval = 0.075

    let taskID: String
    let path: String
    let scheduler: any Scheduling
    private let initialLoads: EventInitialLoadQueue
    private var initialActivityID: UUID?
    private var initialSummaryID: UUID?
    @Subjected var history = EventHistoryState(isLoading: true)
    @Subjected var summary = EventSummary()
    private let summaryQueue = DispatchQueue(label: "dev.polybridge.monitor.summary")
    private var summaryStopped = false
    private var summaryRetry: DispatchWorkItem?
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
    private let activityQueue = DispatchQueue(label: "dev.polybridge.monitor.activity", qos: .utility)
    private var activityEpoch = 0
    private var activityStopped = true
    private var pageRequested = false

    /// One buffered tailer callback, applied in arrival order by `applyPending()` — preserved as a
    /// queue (not merged eagerly) so a `reset` batch still clears exactly what came before it and
    /// nothing after, even though several callbacks may be sitting in the buffer at once.
    private struct PendingBatch: Sendable {
        let events: [TaskEvent]
        let reset: Bool
    }

    private let bufferLock = NSRecursiveLock()
    private var pendingBatches: [PendingBatch] = []
    private var pendingAvailability: EventAvailability?
    private var flushToken: AnyCancellable?

    init(taskID: String, path: String, scheduler: any Scheduling, initialLoads: EventInitialLoadQueue) {
        self.taskID = taskID
        self.path = path
        self.scheduler = scheduler
        self.initialLoads = initialLoads
    }

    func start() {
        bufferLock.lock()
        activityEpoch += 1
        let epoch = activityEpoch
        activityStopped = false
        pageRequested = false
        history = EventHistoryState(isLoading: true)
        let id = UUID()
        initialActivityID = id
        initialLoads.submit(id: id) { [weak self] completion in
            guard let self else { completion(); return }
            startActivityRead(epoch: epoch, completion: completion)
        }
        bufferLock.unlock()
    }

    private func startActivityRead(epoch: Int, completion: @escaping @Sendable () -> Void) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard !activityStopped, activityEpoch == epoch else { completion(); return }
        let tailer = EventFileTailer(path: path, historyHandler: { [weak self] value in
            guard let self else { if !value.isLoading { completion() }; return }
            enqueueHistory(value, epoch: epoch, completion: !value.isLoading ? completion : nil)
        }) { [weak self] newEvents, reset, availability in
            self?.enqueue(newEvents, reset: reset, availability: availability, epoch: epoch)
        }
        self.tailer = tailer
        tailer.start()
    }

    @discardableResult func loadMore() -> Bool {
        bufferLock.lock()
        guard !activityStopped, !pageRequested, !history.isLoading, history.hasMore, let tailer else {
            bufferLock.unlock()
            return false
        }
        pageRequested = true
        var value = history
        value.isLoading = true
        value.error = nil
        history = value
        bufferLock.unlock()
        tailer.loadMore()
        return true
    }

    private func enqueueHistory(_ value: EventHistoryState, epoch: Int, completion: (@Sendable () -> Void)? = nil) {
        activityQueue.async { [weak self] in
            defer { completion?() }
            guard let self else { return }
            bufferLock.lock()
            defer { bufferLock.unlock() }
            guard !activityStopped, activityEpoch == epoch else { return }
            if !value.isLoading { pageRequested = false }
            if history != value { history = value }
        }
    }

    func loadMoreSummaryFiles() {
        summaryQueue.async { [weak self] in
            guard let self else { return }
            summaryFileLimit += 100
            summary = summaryBuilder.snapshot(fileLimit: summaryFileLimit)
        }
    }

    func startSummary() {
        bufferLock.lock()
        let id = UUID()
        initialSummaryID = id
        initialLoads.submit(id: id) { [weak self] completion in
            guard let self else { completion(); return }
            summaryQueue.async { [weak self] in
                guard let self else { completion(); return }
                readSummary(tail: LineTail(maxChunk: 64 << 10), completion: completion)
            }
        }
        bufferLock.unlock()
    }

    private func readSummary(tail initial: LineTail, completion: (@Sendable () -> Void)? = nil) {
        guard !summaryStopped else { completion?(); return }
        var tail = initial
        tail.maxLines = EventPages.pageSize
        guard let step = tail.read(path: path) else {
            summaryBuilder.setAvailability(.unavailable)
            summary = summaryBuilder.snapshot(fileLimit: summaryFileLimit)
            completion?()
            // read(path:) can mutate its cursor before a seek/read fails. Commit only successful reads.
            scheduleSummaryRetry(tail: initial)
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
            let nextTail = tail
            summaryQueue.async { [weak self] in
                guard let self else { completion?(); return }
                readSummary(tail: nextTail, completion: completion)
            }
        } else {
            completion?()
            scheduleSummaryRetry(tail: tail)
        }
    }

    private func scheduleSummaryRetry(tail: LineTail) {
        summaryRetry?.cancel()
        let retry = DispatchWorkItem { [weak self] in self?.readSummary(tail: tail) }
        summaryRetry = retry
        summaryQueue.asyncAfter(deadline: .now() + 1, execute: retry)
    }

    func stopActivity() {
        bufferLock.lock()
        if let initialActivityID { initialLoads.cancel(initialActivityID) }
        initialActivityID = nil
        activityStopped = true
        activityEpoch += 1
        pageRequested = false
        flushToken?.cancel()
        flushToken = nil
        pendingBatches = []
        pendingAvailability = nil
        let epoch = activityEpoch
        activityQueue.async { [weak self] in
            guard let self else { return }
            bufferLock.lock()
            defer { bufferLock.unlock() }
            guard activityStopped, activityEpoch == epoch else { return }
            timelineBuilder = TimelineBuilder()
            if !events.isEmpty { events = [] }
            if !items.isEmpty { items = [] }
        }
        bufferLock.unlock()
        tailer?.stop()
        tailer = nil
    }

    func stop() {
        bufferLock.lock()
        if let initialSummaryID { initialLoads.cancel(initialSummaryID) }
        initialSummaryID = nil
        bufferLock.unlock()
        summaryQueue.async { [weak self] in
            self?.summaryStopped = true
            self?.summaryRetry?.cancel()
            self?.summaryRetry = nil
        }
        stopActivity()
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
    private func enqueue(_ newEvents: [TaskEvent], reset: Bool, availability: EventAvailability, epoch: Int) {
        let isPureDeltaBurst = !reset && !newEvents.isEmpty && newEvents.allSatisfy(\.isAssistantDelta)
        bufferLock.lock()
        guard !activityStopped, activityEpoch == epoch else { bufferLock.unlock(); return }
        pendingBatches.append(PendingBatch(events: newEvents, reset: reset))
        pendingAvailability = availability
        if isPureDeltaBurst {
            if flushToken == nil {
                flushToken = scheduler.schedule(after: Self.coalesceWindow) { [weak self] in
                    self?.applyPending(expectedEpoch: epoch)
                }
            }
            bufferLock.unlock()
            return
        }
        flushToken?.cancel()
        flushToken = nil
        bufferLock.unlock()
        applyPending(expectedEpoch: epoch)
    }

    /// Drain under the buffer lock and enqueue in that same critical section. The serial worker
    /// orders timer and terminal flushes while expensive folding leaves the main actor free.
    private func applyPending(expectedEpoch: Int) {
        bufferLock.lock()
        guard activityEpoch == expectedEpoch else { bufferLock.unlock(); return }
        let batches = pendingBatches
        let availability = pendingAvailability
        let epoch = activityEpoch
        pendingBatches = []
        pendingAvailability = nil
        flushToken = nil
        guard !activityStopped, !batches.isEmpty else { bufferLock.unlock(); return }
        // Enqueue while holding the buffer lock so timer and immediate flushes retain order.
        activityQueue.async { [weak self] in
            self?.fold(batches, availability: availability, epoch: epoch)
        }
        bufferLock.unlock()
    }

    private func fold(_ batches: [PendingBatch], availability: EventAvailability?, epoch: Int) {
        bufferLock.lock()
        let valid = !activityStopped && activityEpoch == epoch
        bufferLock.unlock()
        guard valid else { return }
        let started = MonitorMetrics.begin()
        var next = events
        var builder = timelineBuilder
        for batch in batches {
            if batch.reset {
                next = []
                builder = TimelineBuilder()
            }
            var known = Set(next.map(\.seq))
            let additions = batch.events.filter { known.insert($0.seq).inserted }
            let prepend = additions.first.map { first in next.first.map { first.seq < $0.seq } ?? false } ?? false
            next.append(contentsOf: additions)
            if prepend {
                next.sort { $0.seq < $1.seq }
                builder = TimelineBuilder()
                builder.append(next)
            } else {
                builder.append(additions)
            }
        }
        let nextItems = builder.items
        let eventsChanged = events != next
        let itemsChanged = items != nextItems
        MonitorMetrics.end(started, stage: .activityFold, backgroundThread: !Thread.isMainThread)
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard !activityStopped, activityEpoch == epoch else { return }
        timelineBuilder = builder
        if eventsChanged { events = next }
        if itemsChanged { items = nextItems }
        if let availability, eventsAvailability != availability { eventsAvailability = availability }
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
