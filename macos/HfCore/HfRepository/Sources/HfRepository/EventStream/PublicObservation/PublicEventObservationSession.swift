import Combine
import Foundation
import MonitorCore
import os

// MARK: - PublicEventObservationSession

/// Serial, off-main coordinator. No production consumer is installed by this type.
final class PublicEventObservationSession: Sendable {
    typealias Delivery = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Publisher = @Sendable (PublicEventObservationSnapshot) -> Void
    private enum Lane: Int { case live, older, summary }
    private struct State: Sendable {
        var snapshot: PublicEventObservationSnapshot
        var reducer = PublicEventSummaryReducer()
        var busy = false
        var liveDemand = true
        var liveForwardPages = 0
        var olderDemand = false
        var summaryCursor: String?
        var summarySeeking = false
        var summaryDemand = false
        var summaryFollowLive = false
        var summaryForwardPages = 0
        var nextLane = 0
        var admission = 0
        var resetUsed = false
        var capacityBlocked = false
        var publicationPending = false
        var forwardTerminalSeq: Int?
        var bootstrapFinished = false
        var budgetID: UUID?
        var subscribers: [UUID: Publisher] = [:]
        var delivered: [UUID: PublicEventObservationSnapshot] = [:]
    }

    let id: UUID
    private let taskID: String
    private let reader: any PublicEventObservationReader
    private let budget: any PublicEventObservationAdmission
    private let delivery: Delivery
    private let queue = DispatchQueue(label: "dev.harflow.mac.public-events", qos: .utility)
    private let state: OSAllocatedUnfairLock<State>
    private let operation = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let timer = ObservationTimer()

    init(taskID: String, reader: any PublicEventObservationReader, scheduler: any Scheduling,
         budget: any PublicEventObservationAdmission, delivery: @escaping Delivery) {
        let id = UUID()
        self.id = id
        self.taskID = taskID
        self.reader = reader
        self.budget = budget
        self.delivery = delivery
        self.state = OSAllocatedUnfairLock(initialState: State(snapshot: .init(sessionID: id)))
        let token = scheduler.scheduleRepeating(every: 1) { [weak self] in self?.tick() }
        timer.set(token)
    }

    var snapshot: PublicEventObservationSnapshot { state.withLock { $0.snapshot } }

    func subscribe(id: UUID, publish: @escaping Publisher) {
        state.withLock { $0.subscribers[id] = publish }
        publishLatest()
        queue.async { [self] in pump() }
    }

    func unsubscribe(id: UUID) {
        state.withLock { $0.subscribers.removeValue(forKey: id); $0.delivered.removeValue(forKey: id) }
    }

    func tick() {
        state.withLock { value in
            value.liveDemand = true
            value.liveForwardPages = 0
            value.summaryForwardPages = 0
            if value.snapshot.summaryPhase == .caughtUp { value.summaryDemand = true }
        }
        queue.async { [self] in pump() }
    }

    func requestOlder() {
        state.withLock { $0.olderDemand = true }
        queue.async { [self] in pump() }
    }

    /// Synchronous epoch fence, including notified selection ABA.
    func fenceRuntime() {
        state.withLock { value in
            let revision = value.snapshot.revision + 1
            let work = value.snapshot.historicalOperations
            value.snapshot = .init(sessionID: id)
            value.snapshot.revision = revision
            value.snapshot.historicalOperations = work
            value.snapshot.stopped = true
        }
    }

    func invalidateRuntime() {
        fenceRuntime()
        stop()
    }

    func stop() {
        state.withLock { $0.snapshot.stopped = true }
        let budgetID = state.withLock { $0.budgetID }
        if let budgetID { budget.cancel(budgetID) }
        timer.cancel()
        let running = operation.withLock { value -> Task<Void, Never>? in defer { value = nil }; return value }
        running?.cancel()
        publishLatest()
    }

    private func pump() {
        let request = state.withLock { value -> (Lane, TaskEventPagePosition, UUID)? in
            guard !value.snapshot.stopped, !value.busy else { return nil }
            if !value.bootstrapFinished, !value.capacityBlocked, value.liveDemand {
                value.liveDemand = false
                value.busy = true
                return (.live, .newest, value.snapshot.epoch)
            }
            return nextRequest(value: &value)
        }
        guard let (lane, position, epoch) = request else { publishLatest(); return }
        let budgetID = UUID()
        state.withLock { $0.budgetID = budgetID }
        budget.submit(id: budgetID) { [self] done in
            let task = Task {
                let current: @Sendable () -> Bool = { [self] in
                    state.withLock { !$0.snapshot.stopped && $0.snapshot.epoch == epoch }
                }
                guard current() else { done(); return }
                let result = await reader.read(taskID: taskID, position: position, operationIsCurrent: current)
                done()
                queue.async { [self] in
                    apply(result, lane: lane, position: position, epoch: epoch)
                    publishLatest()
                    // A queue turn is an explicit executor yield; never synchronously drain.
                    queue.async { [self] in pump() }
                }
            }
            operation.withLock { $0 = task }
            if state.withLock({ $0.snapshot.stopped }) { task.cancel() }
        }
        // Cancellation may have raced registration or the asynchronous admission enqueue.
        if state.withLock({ $0.snapshot.stopped }) { budget.cancel(budgetID) }
    }

    private func nextRequest(value: inout State) -> (Lane, TaskEventPagePosition, UUID)? {
        for offset in 0 ..< 3 {
            let index = (value.nextLane + offset) % 3
            guard let lane = Lane(rawValue: index), let cursor = cursor(for: lane, value: &value) else { continue }
            value.nextLane = (index + 1) % 3
            value.busy = true
            if lane == .live { value.liveForwardPages += 1 }
            if lane == .summary {
                if value.summaryFollowLive { value.summaryForwardPages += 1 } else { value.snapshot.historicalOperations += 1 }
            }
            return (lane, .cursor(cursor), value.snapshot.epoch)
        }
        return nil
    }

    private func cursor(for lane: Lane, value: inout State) -> String? {
        switch lane {
        case .live:
            guard value.liveDemand, value.liveForwardPages < 2, !value.capacityBlocked else { return nil }
            value.liveDemand = false
            return value.snapshot.liveCursor
        case .older:
            guard value.olderDemand, !value.capacityBlocked else { return nil }
            value.olderDemand = false
            return value.snapshot.olderCursor
        case .summary:
            return summaryCursor(value: &value)
        }
    }

    private func summaryCursor(value: inout State) -> String? {
        let demanded = value.snapshot.summaryPhase != .caughtUp || value.summaryDemand
        guard demanded else { return nil }
        guard !value.summaryFollowLive || value.summaryForwardPages < 2 else { return nil }
        if value.summaryFollowLive || value.snapshot.historicalOperations < 4096 {
            value.summaryDemand = false
            return value.summaryCursor
        }
        if value.summaryCursor != nil {
            value.summaryCursor = nil
            value.snapshot.summaryPhase = .limited
            value.snapshot.issues.insert(.historicalLimit)
            value.reducer.qualify(.historicalLimit)
            value.snapshot.summary = value.reducer.snapshot(caughtUp: false)
        }
        return nil
    }

    private func apply(_ result: Result<TaskEventPage, ToolError>, lane: Lane,
                       position: TaskEventPagePosition, epoch: UUID) {
        state.withLock { value in
            guard !value.snapshot.stopped, value.snapshot.epoch == epoch else { return }
            value.busy = false
            value.budgetID = nil
            let before = value.snapshot
            defer {
                value.snapshot.summary = value.reducer.snapshot(caughtUp: value.snapshot.summaryPhase == .caughtUp)
                if value.snapshot != before { value.snapshot.revision += 1 }
            }
            switch result {
            case .failure(let error): applyFailure(error, lane: lane, value: &value)
            case .success(let page): applyPage(page, lane: lane, position: position, epoch: epoch, value: &value)
            }
        }
    }

    private func applyFailure(_ error: ToolError, lane: Lane, value: inout State) {
        value.snapshot.error = error
        if error.refusalCode == "cursor_expired" || error.refusalCode == "cursor_invalid" {
            guard !value.resetUsed else {
                value.snapshot.issues.insert(.resetExhausted)
                value.reducer.qualify(.requestUnavailable)
                value.summaryCursor = nil
                value.snapshot.summaryPhase = .unavailable
                return
            }
            reset(value: &value)
        } else {
            value.snapshot.issues.insert(.unavailable)
            if lane == .summary {
                value.reducer.qualify(.requestUnavailable)
                value.summaryCursor = nil; value.snapshot.summaryPhase = .unavailable
            }
        }
    }

    private func reset(value: inout State) {
        value.resetUsed = true
        let work = min(4096, value.snapshot.historicalOperations + 1)
        let coverage = value.snapshot.coverage
        let issues = value.snapshot.issues
        value.snapshot = .init(sessionID: id)
        value.snapshot.coverage = coverage
        value.snapshot.issues = issues
        value.snapshot.historicalOperations = work
        value.bootstrapFinished = false
        value.forwardTerminalSeq = nil
        value.admission = 0
        value.summarySeeking = false
        value.summaryDemand = false
        value.summaryFollowLive = false
        value.summaryForwardPages = 0
        value.olderDemand = false
        value.reducer = PublicEventSummaryReducer()
        value.summaryCursor = nil
        value.capacityBlocked = false
        value.liveDemand = true
        value.liveForwardPages = 0
    }

    private func applyPage(_ page: TaskEventPage, lane: Lane, position: TaskEventPagePosition, epoch: UUID, value: inout State) {
        value.snapshot.error = nil
        guard page.log.state != .unavailable else {
            value.reducer.qualify(.requestUnavailable)
            value.snapshot.lifecycle = page.log
            value.snapshot.forwardDrained = false
            value.forwardTerminalSeq = nil
            value.snapshot.issues.insert(.unavailable)
            value.snapshot.summaryPhase = .unavailable
            value.summaryCursor = nil
            return
        }
        let bootstrap = position == .newest
        if bootstrap { value.bootstrapFinished = true }
        guard progresses(page, lane: lane, position: position, value: &value) else { return }
        if lane != .summary, !admitActivity(page, lane: lane, bootstrap: bootstrap, epoch: epoch, value: &value) { return }
        applySummary(page, lane: lane, bootstrap: bootstrap, value: &value)
        if value.reducer.isUnavailable || value.reducer.isLimited {
            value.summaryCursor = nil
            value.snapshot.summaryPhase = value.reducer.isLimited ? .limited : .unavailable
        }
        value.snapshot.summary = value.reducer.snapshot(caughtUp: value.snapshot.summaryPhase == .caughtUp)
    }

    private func progresses(_ page: TaskEventPage, lane: Lane, position: TaskEventPagePosition, value: inout State) -> Bool {
        if case .cursor(let previous) = position {
            let backwards = lane == .older || (lane == .summary && value.summarySeeking)
            let next = backwards ? page.olderCursor : page.newerCursor
            let more = backwards ? page.hasOlder : page.hasNewer
            if more, next == previous {
                value.snapshot.issues.insert(.nonprogress)
                if lane == .live { value.liveDemand = false }
                if lane == .summary {
                    value.reducer.qualify(.nonprogress)
                    value.summaryCursor = nil; value.snapshot.summaryPhase = .unavailable
                }
                return false
            }
        }
        return true
    }

    private func admitActivity(_ page: TaskEventPage, lane: Lane, bootstrap: Bool, epoch: UUID, value: inout State) -> Bool {
        let bytes = page.events.reduce(0) { $0 + JSONValue.object($1.raw).rendered().utf8.count }
        guard page.events.count <= 2000 - value.snapshot.activity.count,
              bytes <= 4 * 1024 * 1024 - value.snapshot.rawBytes else {
            value.capacityBlocked = true
            value.snapshot.issues.insert(.capacity)
            value.snapshot.hasPendingLive = true
            if bootstrap { configureSummary(page, value: &value) }
            return false
        }
        let records = page.events.map { record -> PublicEventOccurrence in
            value.admission += 1
            return .init(epoch: epoch, admission: value.admission, record: record)
        }
        if lane == .older {
            value.snapshot.activity.insert(contentsOf: records, at: 0)
        } else {
            value.snapshot.activity.append(contentsOf: records)
        }
        value.snapshot.rawBytes += bytes
        accountCoverage(page, value: &value)
        if lane == .older || bootstrap { value.snapshot.olderCursor = page.olderCursor }
        if lane == .live {
            value.snapshot.liveCursor = page.newerCursor
            value.snapshot.lifecycle = page.log
            if let final = page.log.finalSeq, page.events.contains(where: { $0.seq == final && $0.kind == "task_finished" }) {
                value.forwardTerminalSeq = final
            }
            value.snapshot.forwardDrained = !bootstrap && !page.hasNewer && page.log.state == .final
                && page.log.finalSeq != nil && page.log.finalSeq == value.forwardTerminalSeq
            value.snapshot.hasPendingLive = page.hasNewer
            value.liveDemand = page.hasNewer && value.liveForwardPages < 2
        }
        return true
    }

    private func applySummary(_ page: TaskEventPage, lane: Lane, bootstrap: Bool, value: inout State) {
        if bootstrap {
            configureSummary(page, value: &value)
        } else if lane == .summary {
            if value.summarySeeking {
                value.reducer.noteSeek(page)
                if page.hasOlder {
                    value.summaryCursor = page.olderCursor
                } else {
                    value.summarySeeking = false
                    value.reducer.fold(page)
                    value.summaryCursor = page.newerCursor
                    value.snapshot.summaryPhase = .replaying
                }
            } else {
                value.reducer.fold(page)
                value.summaryCursor = page.newerCursor
                value.snapshot.summaryPhase = page.hasNewer ? .replaying : .caughtUp
                value.snapshot.summaryDeliveryCursor = page.newerCursor
                if !page.hasNewer { value.summaryFollowLive = true }
            }
        }
    }

    private func accountCoverage(_ page: TaskEventPage, value: inout State) {
        func add(_ lhs: Int, _ rhs: Int) -> Int {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? Int.max : result.partialValue
        }
        value.snapshot.coverage.malformed = add(value.snapshot.coverage.malformed, page.skipped.malformed)
        value.snapshot.coverage.oversized = add(value.snapshot.coverage.oversized, page.skipped.oversized)
        value.snapshot.coverage.gaps = add(value.snapshot.coverage.gaps, page.gaps.count)
        var previous: Int?
        let known: Set = ["task_started", "assistant_text", "assistant_delta", "tool_call",
                                  "tool_result", "user_message", "usage", "notice", "task_finished", "undelivered"]
        for record in page.events {
            if record.truncated == true || record.oversized == true {
                value.snapshot.coverage.truncatedRecords = add(value.snapshot.coverage.truncatedRecords, 1)
            }
            if !known.contains(record.kind) {
                value.snapshot.coverage.unknownKinds = add(value.snapshot.coverage.unknownKinds, 1)
            }
            if let previous, record.seq <= previous {
                value.snapshot.coverage.nonIncreasingSequences = add(value.snapshot.coverage.nonIncreasingSequences, 1)
            }
            previous = record.seq
        }
    }

    private func configureSummary(_ page: TaskEventPage, value: inout State) {
        if page.hasOlder {
            value.reducer.noteSeek(page)
            value.summarySeeking = true
            value.summaryCursor = page.olderCursor
            value.snapshot.summaryPhase = .seeking
        } else {
            value.reducer.fold(page)
            value.summarySeeking = false
            value.summaryCursor = page.newerCursor
            value.snapshot.summaryPhase = .replaying
        }
    }

    /// One latest-value mailbox; delivery rechecks epoch and subscription identity.
    private func publishLatest() {
        let scheduledEpoch = state.withLock { value -> UUID? in
            guard !value.publicationPending else { return nil }
            value.publicationPending = true
            return value.snapshot.epoch
        }
        guard let scheduledEpoch else { return }
        delivery { [weak self] in
            guard let self else { return }
            let deliveries = state.withLock { value -> [(UUID, Publisher, PublicEventObservationSnapshot)] in
                value.publicationPending = false
                guard value.snapshot.epoch == scheduledEpoch, !value.snapshot.stopped else { return [] }
                var deliveries: [(UUID, Publisher, PublicEventObservationSnapshot)] = []
                for (id, publisher) in value.subscribers where value.delivered[id] != value.snapshot {
                    value.delivered[id] = value.snapshot
                    deliveries.append((id, publisher, value.snapshot))
                }
                return deliveries
            }
            for (subscriberID, publisher, snapshot) in deliveries {
                guard state.withLock({ !$0.snapshot.stopped && $0.snapshot.epoch == snapshot.epoch && $0.subscribers[subscriberID] != nil }) else { continue }
                publisher(snapshot)
            }
            if state.withLock({ !$0.snapshot.stopped && $0.snapshot.epoch != scheduledEpoch }) { publishLatest() }
        }
    }
}

// MARK: - ObservationTimer

/// Combine cancellation token isolated behind a lock; cancellation runs after unlocking.
private final class ObservationTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var token: AnyCancellable?

    func set(_ value: AnyCancellable) { lock.withLock { token = value } }
    func cancel() {
        let current = lock.withLock { () -> AnyCancellable? in
            defer { token = nil }
            return token
        }
        current?.cancel()
    }
}
