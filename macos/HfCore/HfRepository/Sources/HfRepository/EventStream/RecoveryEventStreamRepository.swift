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
        session.start()
        lock.unlock()
        return RecoveryActivityLease(taskID: taskID, base: baseLease) { [weak self] in self?.release(taskID) }
    }

    private func release(_ taskID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[taskID] else { return }
        session.references -= 1
        if session.references == 0 {
            sessions[taskID] = nil
            session.stop()
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
        return base.eventsPublisher(for: id)
.combineLatest(session.$state)
            .receive(on: presentationQueue)
.map { $0 + $1.events }
.removeDuplicates()
            .receive(on: DispatchQueue.main)
.eraseToAnyPublisher()
    }

    public func itemsPublisher(for id: String) -> AnyPublisher<[TimelineItem], Never> {
        guard let session = session(id) else { return base.itemsPublisher(for: id) }
        return base.itemsPublisher(for: id)
.combineLatest(session.$state)
            .receive(on: presentationQueue)
.map { $0 + $1.items }
.removeDuplicates()
            .receive(on: DispatchQueue.main)
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
    var events: [TaskEvent] = []
    var items: [TimelineItem] = []
}

private final class RecoveryActivitySession: @unchecked Sendable {
    let taskID: String
    var references = 0
    @Subjected var state = RecoveryActivityState()
    private let environment: any ToolEnvironmentRepository
    private let snapshots: any TaskSnapshotRepository
    private let scheduler: any Scheduling
    private let lock = NSRecursiveLock()
    private var generation = UUID()
    private var active = false
    private var poll: Task<Void, Never>?
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
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return }
        active = true
        subscription = snapshots.snapshotsPublisher().sink { [weak self] _ in self?.refresh() }
        timer = scheduler.scheduleRepeating(every: 5) { [weak self] in self?.refresh() }
        refresh()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        generation = UUID()
        poll?.cancel()
        poll = nil
        timer?.cancel()
        timer = nil
        subscription?.cancel()
        subscription = nil
    }

    private func isCurrent(_ expected: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, generation == expected else { return false }
        guard let selectedExecutable, let selectedContext,
              case .success(let client) = environment.ctl() else { return false }
        return client.executable == selectedExecutable && client.compatibilityContext == selectedContext
    }

    private func refresh() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        guard snapshots.snapshot(taskID)?.supervision?.captureState == "lost_with_owner" else {
            generation = UUID()
            poll?.cancel()
            poll = nil
            cursor = nil
            records = []
            if state != RecoveryActivityState() { state = RecoveryActivityState() }
            return
        }
        if case .success(let client) = environment.ctl(),
           selectedExecutable != client.executable || selectedContext != client.compatibilityContext {
            generation = UUID()
            poll?.cancel()
            poll = nil
            cursor = nil
            records = []
            unsupported = false
            selectedExecutable = client.executable
            selectedContext = client.compatibilityContext
            if state != RecoveryActivityState() { state = RecoveryActivityState() }
        }
        guard poll == nil, !unsupported else { return }
        let expected = generation
        let cursor = cursor
        poll = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result: Result<RecoveryActivityPage, ToolError>
            switch environment.ctl() {
            case .failure(let error): result = .failure(error)
            case .success(var client):
                client.operationIsCurrent = { [weak self] in self?.isCurrent(expected) == true }
                result = await client.recoveryActivity(taskID, cursor: cursor)
            }
            apply(result, generation: expected)
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
        lock.lock()
        defer { lock.unlock() }
        guard active, generation == expected, !Task.isCancelled else { return }
        poll = nil
        guard isCurrent(expected) else { return }
        let provenance = notice(
            "Backend transcript recovery · display only. These entries do not establish task outcome or restore live input.",
            sourceID: "provenance"
        )
        var notices: [TaskEvent] = []
        switch result {
        case .failure(let error):
            if case .unsupportedCommand = error { unsupported = true }
            if let event = notice("Backend transcript recovery unavailable: \(error.message)", sourceID: "error:\(error.message)") { notices.append(event) }
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
        let next = RecoveryActivityState(events: events, items: Timeline.items(from: events))
        if state != next { state = next }
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
            notice("Backend transcript: \(text)", sourceID: "notice:\(text)")
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
