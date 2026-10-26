import Combine
import Foundation
import HfUtilities
import MonitorCore

// MARK: - RecoveryEventStreamRepository

/// Adds source-labelled transcript activity without changing captured history, summaries or outcome.
/// Each activity lease owns a bounded, cancellable recovery session; summary leases do no extra I/O.
public final class RecoveryEventStreamRepository: EventStreamRepository, @unchecked Sendable {
    private let base: any EventStreamRepository
    private let environment: any ToolEnvironmentRepository
    private let snapshots: any TaskSnapshotRepository
    private let scheduler: any Scheduling
    private let lock = NSRecursiveLock()
    private var sessions: [String: RecoveryActivitySession] = [:]
    private let presentationQueue = DispatchQueue(label: "dev.harflow.mac.recovery.presentation", qos: .utility)

    public init(base: any EventStreamRepository, environment: any ToolEnvironmentRepository,
                snapshots: any TaskSnapshotRepository, scheduler: any Scheduling) {
        self.base = base
        self.environment = environment
        self.snapshots = snapshots
        self.scheduler = scheduler
    }

    public func acquire(_ taskID: String) -> any EventStreamLease {
        let baseLease = base.acquire(taskID)
        lock.lock()
        let session: RecoveryActivitySession
        if let existing = sessions[taskID] {
            session = existing
        } else {
            session = RecoveryActivitySession(taskID: taskID, environment: environment, snapshots: snapshots, scheduler: scheduler)
            sessions[taskID] = session
        }
        session.references += 1
        lock.unlock()
        session.start()
        return RecoveryActivityLease(taskID: taskID, base: baseLease) { [weak self] in self?.release(taskID) }
    }

    private func release(_ taskID: String) {
        lock.lock()
        guard let session = sessions[taskID] else { lock.unlock(); return }
        session.references -= 1
        if session.references == 0 {
            sessions[taskID] = nil
            lock.unlock()
            session.stop()
        } else {
            lock.unlock()
        }
    }

    private func session(_ id: String) -> RecoveryActivitySession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    public func acquireSummary(_ id: String) -> any EventStreamLease { base.acquireSummary(id) }
    public func events(for id: String) -> [TaskEvent] { base.events(for: id) + (session(id)?.state.events ?? []) }
    public func items(for id: String) -> [TimelineItem] { base.items(for: id) + (session(id)?.state.items ?? []) }
    public func eventsPublisher(for id: String) -> AnyPublisher<[TaskEvent], Never> {
        guard let session = session(id) else { return base.eventsPublisher(for: id) }
        let merged: AnyPublisher<(generation: UUID?, events: [TaskEvent]), Never> = base.eventsPublisher(for: id)
.combineLatest(session.publisher)
            .receive(on: presentationQueue)
.map { captured, _ in
                let recovery = session.state
                return (generation: recovery.generation, events: captured + recovery.events)
            }
.removeDuplicates { $0.generation == $1.generation && $0.events == $1.events }
.eraseToAnyPublisher()
        return merged.receive(on: DispatchQueue.main)
.compactMap { session.accepts($0.generation) ? $0.events : nil }
.eraseToAnyPublisher()
    }

    public func itemsPublisher(for id: String) -> AnyPublisher<[TimelineItem], Never> {
        guard let session = session(id) else { return base.itemsPublisher(for: id) }
        let merged: AnyPublisher<(generation: UUID?, items: [TimelineItem]), Never> = base.itemsPublisher(for: id)
.combineLatest(session.publisher)
            .receive(on: presentationQueue)
.map { captured, _ in
                let recovery = session.state
                return (generation: recovery.generation, items: captured + recovery.items)
            }
.removeDuplicates { $0.generation == $1.generation && $0.items == $1.items }
.eraseToAnyPublisher()
        return merged.receive(on: DispatchQueue.main)
.compactMap { session.accepts($0.generation) ? $0.items : nil }
.eraseToAnyPublisher()
    }

    public func loadMoreSummaryFiles(_ id: String) { base.loadMoreSummaryFiles(id) }
    @discardableResult public func loadMore(_ id: String) -> Bool { base.loadMore(id) }
    public func history(for id: String) -> EventHistoryState { base.history(for: id) }
    public func historyPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { base.historyPublisher(for: id) }
    public func summary(for id: String) -> EventSummary { base.summary(for: id) }
    public func summaryPublisher(for id: String) -> AnyPublisher<EventSummary, Never> { base.summaryPublisher(for: id) }
    public func eventsAvailability(for id: String) -> EventAvailability { base.eventsAvailability(for: id) }
    public func eventsAvailabilityPublisher(for id: String) -> AnyPublisher<EventAvailability, Never> { base.eventsAvailabilityPublisher(for: id) }
    public func current(for id: String) -> TimelineItem? { base.current(for: id) }
    public func activity(for id: String) -> ActivityCounts { base.activity(for: id) }
    public func prompt(for id: String) -> String? { base.prompt(for: id) }
    public var leasedTaskIDs: Set<String> { base.leasedTaskIDs }
}

// MARK: - RecoveryActivitySession

private struct RecoveryActivityState: Equatable, Sendable {
    var generation: UUID?
    var events: [TaskEvent] = []
    var items: [TimelineItem] = []
}

private final class RecoveryActivitySession: @unchecked Sendable {
    let taskID: String
    var references = 0
    @Subjected private var publishedState = RecoveryActivityState()
    // Only lifetime validity is shared with callers. Never hold this lock across repository
    // reads, cancellation, subscription setup or synchronous Combine publication.
    private let lifetimeLock = NSLock()
    private var active = true
    private var refreshQueued = false
    private let queue = DispatchQueue(label: "dev.harflow.mac.recovery.session", qos: .utility)
    private var started = false

    var state: RecoveryActivityState {
        let value = publishedState
        guard isActive, value.generation.map(isValid) ?? true else { return RecoveryActivityState() }
        return value
    }

    var publisher: AnyPublisher<RecoveryActivityState, Never> {
        $publishedState.map { [weak self] value in
            self?.isActive == true ? value : RecoveryActivityState()
        }
.eraseToAnyPublisher()
    }

    /// A queued merged snapshot is discarded if its recovery generation was invalidated.
    func accepts(_ generation: UUID?) -> Bool { generation.map(isValid) ?? true }

    private var isActive: Bool {
        lifetimeLock.lock()
        defer { lifetimeLock.unlock() }
        return active
    }

    private let environment: any ToolEnvironmentRepository
    private let snapshots: any TaskSnapshotRepository
    private let scheduler: any Scheduling
    // The command's synchronous currentness callback reads this token without joining queue work.
    private var generation = UUID()

    private func currentGeneration() -> UUID {
        lifetimeLock.lock()
        defer { lifetimeLock.unlock() }
        return generation
    }

    private func invalidateGeneration() {
        lifetimeLock.lock()
        generation = UUID()
        lifetimeLock.unlock()
    }

    private func isValid(_ expected: UUID) -> Bool {
        lifetimeLock.lock()
        defer { lifetimeLock.unlock() }
        return active && generation == expected
    }

    private var poll: Task<Void, Never>?
    private var pollGeneration: UUID?
    private var timer: AnyCancellable?
    private var subscription: AnyCancellable?
    private var cursor: String?
    private var records: [TaskEvent] = []
    private var identities: [String: Int] = [:]
    private var nextIdentity = Int.max / 2
    private var unsupported = false
    private var selectedExecutable: String?
    private var selectedContext: RuntimeCompatibilityContext?

    init(taskID: String, environment: any ToolEnvironmentRepository, snapshots: any TaskSnapshotRepository, scheduler: any Scheduling) {
        self.taskID = taskID
        self.environment = environment
        self.snapshots = snapshots
        self.scheduler = scheduler
    }

    func start() {
        queue.async { [self] in
            guard isActive, !started else { return }
            started = true
            // A Subjected publisher invokes its sink while its own lock is held. The sink
            // must only enqueue; it must never synchronously read that repository again.
            subscription = snapshots.snapshotsPublisher().sink { [weak self] values in
                guard let self else { return }
                // Invalidate synchronously from the supplied value, without reading back through
                // Subjected. A delayed command cannot escape while the queue catches up.
                if values[taskID]?.supervision?.captureState != "lost_with_owner" { invalidateGeneration() }
                enqueueRefresh()
            }
            timer = scheduler.scheduleRepeating(every: 5) { [weak self] in self?.enqueueRefresh() }
            refresh()
        }
    }

    func stop() {
        lifetimeLock.lock()
        active = false
        lifetimeLock.unlock()
        // UI teardown never joins a blocked snapshot read, publisher or command completion.
        queue.async { [self] in
            invalidateGeneration()
            poll?.cancel()
            poll = nil
            pollGeneration = nil
            timer?.cancel()
            timer = nil
            subscription?.cancel()
            subscription = nil
        }
    }

    private func enqueueRefresh() {
        lifetimeLock.lock()
        guard active, !refreshQueued else { lifetimeLock.unlock(); return }
        refreshQueued = true
        lifetimeLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            lifetimeLock.lock()
            refreshQueued = false
            lifetimeLock.unlock()
            refresh()
        }
    }

    private func isCurrent(_ expected: UUID, executable: String, context: RuntimeCompatibilityContext) -> Bool {
        guard isValid(expected), case .success(let client) = environment.ctl() else { return false }
        return isValid(expected) && client.executable == executable && client.compatibilityContext == context
    }

    private func refresh() {
        guard isActive else { return }
        guard snapshots.snapshot(taskID)?.supervision?.captureState == "lost_with_owner" else {
            invalidateGeneration()
            poll?.cancel()
            poll = nil
            pollGeneration = nil
            cursor = nil
            records = []
            if isActive, publishedState != RecoveryActivityState() { publishedState = RecoveryActivityState() }
            return
        }
        if case .success(let client) = environment.ctl(),
           selectedExecutable != client.executable || selectedContext != client.compatibilityContext {
            invalidateGeneration()
            poll?.cancel()
            poll = nil
            pollGeneration = nil
            cursor = nil
            records = []
            unsupported = false
            selectedExecutable = client.executable
            selectedContext = client.compatibilityContext
            if isActive, publishedState != RecoveryActivityState() { publishedState = RecoveryActivityState() }
        }
        // A healthy → lost burst can be coalesced before this read. The healthy callback
        // still invalidated the token, so retire that poll even though the latest snapshot
        // is lost again. Its eventual completion must not clear a replacement poll.
        let invalidPoll = pollGeneration.map { !isValid($0) } ?? false
        let invalidState = publishedState.generation.map { !isValid($0) } ?? false
        if invalidPoll || invalidState {
            poll?.cancel()
            poll = nil
            pollGeneration = nil
            cursor = nil
            records = []
            if isActive, publishedState != RecoveryActivityState() { publishedState = RecoveryActivityState() }
        }
        guard isActive, poll == nil, !unsupported,
              let executable = selectedExecutable, let context = selectedContext else { return }
        let expected = currentGeneration()
        let cursor = cursor
        pollGeneration = expected
        poll = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result: Result<RecoveryActivityPage, ToolError>
            switch environment.ctl() {
            case .failure(let error): result = .failure(error)
            case .success(var client):
                client.operationIsCurrent = { [weak self] in self?.isCurrent(expected, executable: executable, context: context) == true }
                result = await client.recoveryActivity(taskID, cursor: cursor)
            }
            queue.async { [weak self] in self?.apply(result, generation: expected) }
        }
    }

    private func identity(_ sourceID: String) -> Int? {
        if let existing = identities[sourceID] { return existing }
        // Retain mappings only for the bounded displayed snapshot. Newly allocated IDs increase
        // in a disjoint upper namespace and are never reused after reset or tail eviction.
        // Ordinary event cursors remain exclusively owned by the captured repository.
        guard nextIdentity < Int.max else { return nil }
        let value = nextIdentity
        nextIdentity += 1
        identities[sourceID] = value
        return value
    }

    private func notice(_ text: String, sourceID: String) -> TaskEvent? {
        guard let id = identity(sourceID) else { return nil }
        return TaskEvent(displayID: id, sourceTimestamp: nil, kind: .notice(text), rawLine: "")
    }

    private func apply(_ result: Result<RecoveryActivityPage, ToolError>, generation expected: UUID) {
        guard isValid(expected), pollGeneration == expected else { return }
        poll = nil
        pollGeneration = nil
        guard let executable = selectedExecutable, let context = selectedContext,
              isCurrent(expected, executable: executable, context: context) else { return }
        let provenance = notice(
            "Harness transcript recovery · display only. These entries do not establish task outcome or restore live input.",
            sourceID: "provenance"
        )
        var notices: [TaskEvent] = []
        switch result {
        case .failure(let error):
            if case .unsupportedCommand = error { unsupported = true }
            if let event = notice("Harness transcript recovery unavailable: \(error.message)", sourceID: "error:\(error.message)") { notices.append(event) }
        case .success(let page):
            notices = applyPage(page)
        }
        var events: [TaskEvent] = []
        if let provenance {
            events.append(provenance)
        }
        events += records + notices
        let retained = Set(events.map(\.seq))
        identities = identities.filter { retained.contains($0.value) }
        let next = RecoveryActivityState(generation: expected, events: events, items: Timeline.items(from: events))
        if isValid(expected), publishedState != next { publishedState = next }
    }

    private func applyPage(_ page: RecoveryActivityPage) -> [TaskEvent] {
        if page.reset { records = [] }
        cursor = page.nextCursor
        var seen = Set(records.map(\.seq))
        for event in page.events {
            guard let id = identity(event.sourceID), seen.insert(id).inserted else { continue }
            records.append(TaskEvent(displayID: id, sourceTimestamp: event.timestamp,
                                     kind: event.kind, rawLine: event.raw.rendered()))
        }
        records = Array(records.suffix(200))
        return page.notices.compactMap { text in
            notice("Harness transcript: \(text)", sourceID: "notice:\(text)")
        }
    }

}

// MARK: - RecoveryActivityLease

private final class RecoveryActivityLease: EventStreamLease, @unchecked Sendable {
    let taskID: String
    private let base: any EventStreamLease
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    init(taskID: String, base: any EventStreamLease, onRelease: @escaping @Sendable () -> Void) {
        self.taskID = taskID
        self.base = base
        self.onRelease = onRelease
    }

    func release() {
        lock.lock()
        let action = onRelease
        onRelease = nil
        lock.unlock()
        guard let action else { return }
        base.release()
        action()
    }

    deinit { release() }
}
