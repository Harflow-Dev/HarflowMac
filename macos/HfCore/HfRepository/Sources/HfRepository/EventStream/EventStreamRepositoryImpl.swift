import Combine
import Foundation
import MonitorCore

// MARK: - EventStreamRepositoryImpl

/// Shared public event observations. Consumer roles survive runtime replacement; source facts do not.
public final class EventStreamRepositoryImpl: EventStreamRepository, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let reader: any PublicEventObservationReader
    private let snapshots: any TaskSnapshotRepository
    private let prompts: any TaskPromptRepository
    private let manager: PublicEventObservationManager
    private let publicationDelivery: PublicEventObservationSession.Delivery
    private var holders: [String: PublicEventHolder] = [:]
    private var runtimeSubscription: AnyCancellable?
    private var generation = UUID()
    private static let unconfiguredScope = EventObservationScope(sessionID: UUID(), sourceID: UUID(), windowID: UUID())

    deinit {
        runtimeSubscription?.cancel()
        for holder in holders.values { holder.promptTask?.cancel() }
        // The manager cancels and fences its sessions during its own teardown.
    }

    public convenience init(toolEnvironment: any ToolEnvironmentRepository, snapshotRepository: any TaskSnapshotRepository,
                            scheduler: any Scheduling, compatibilityCheck: StoreCompatibilityCheck? = nil,
                            promptRepository: any TaskPromptRepository = NullTaskPromptRepository()) {
        self.init(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository, scheduler: scheduler,
                  initialLoads: EventInitialLoadQueue(), compatibilityCheck: compatibilityCheck, promptRepository: promptRepository)
    }

    // Old constructor seams remain source-compatible; public operations own compatibility checks.
    convenience init(toolEnvironment: any ToolEnvironmentRepository, snapshotRepository: any TaskSnapshotRepository,
                     scheduler: any Scheduling, initialLoads _: EventInitialLoadQueue, compatibilityCheck _: StoreCompatibilityCheck? = nil,
                     promptRepository: any TaskPromptRepository = NullTaskPromptRepository()) {
        let queue = DispatchQueue(label: "dev.harflow.mac.public-event-projection", qos: .utility)
        self.init(snapshotRepository: snapshotRepository, scheduler: scheduler,
                  reader: BoundPublicEventObservationReader(tooling: toolEnvironment), promptRepository: promptRepository,
                  delivery: { body in queue.async(execute: body) })
    }

    /// Typed public-page seam; tests never need an installed engine or private event file.
    init(snapshotRepository: any TaskSnapshotRepository, scheduler: any Scheduling,
         reader: any PublicEventObservationReader, promptRepository: any TaskPromptRepository,
         delivery: @escaping PublicEventObservationSession.Delivery,
         publicationDelivery: @escaping PublicEventObservationSession.Delivery = { DispatchQueue.main.async(execute: $0) }) {
        self.reader = reader
        self.snapshots = snapshotRepository
        self.prompts = promptRepository
        self.manager = PublicEventObservationManager(scheduler: scheduler, delivery: delivery)
        self.publicationDelivery = publicationDelivery
    }

    /// Bind actual runtime transitions, including selection ABA, rather than comparing bindings.
    public func bindRuntimeChanges<P: Publisher>(_ publisher: P) where P.Failure == Never {
        runtimeSubscription = publisher.dropFirst().sink { [weak self] _ in self?.invalidateRuntime() }
    }

    public func invalidateRuntime() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
        for holder in holders.values { holder.reset(); publishLatest(holder) }
        manager.invalidateRuntime()
        for holder in holders.values where !holder.roles.isEmpty { connect(holder) }
    }

    private func holder(_ taskID: String) -> PublicEventHolder {
        if let existing = holders[taskID] { return existing }
        let value = PublicEventHolder(taskID: taskID)
        holders[taskID] = value
        return value
    }

    private func connect(_ holder: PublicEventHolder) {
        let token = generation
        let lifetime = holder.lifetime
        holder.lease = manager.acquire(taskID: holder.taskID, reader: reader,
                                       activityEnabled: holder.roles.values.contains(true)) { [weak self, weak holder] snapshot in
            guard let self, let holder else { return }
            let frame = EventObservationFrameProjector.project(taskID: holder.taskID, snapshot: snapshot)
            lock.lock(); defer { lock.unlock() }
            guard generation == token, holders[holder.taskID] === holder, holder.lifetime == lifetime,
                  !holder.roles.isEmpty else { return }
            if holder.apply(frame) { publishLatest(holder) }
        }
        holder.lease?.session.setActivityEnabled(holder.roles.values.contains(true))
    }

    public func acquire(_ taskID: String) -> any EventStreamLease { acquire(taskID, activity: true) }
    public func acquireSummary(_ taskID: String) -> any EventStreamLease { acquire(taskID, activity: false) }
    private func acquire(_ taskID: String, activity: Bool) -> any EventStreamLease {
        lock.lock()
        let value = holder(taskID)
        let firstActivity = activity && !value.roles.values.contains(true)
        let id = UUID()
        value.roles[id] = activity
        if value.lease == nil { connect(value) }
        value.lease?.session.setActivityEnabled(value.roles.values.contains(true))
        lock.unlock()
        if firstActivity { Task { [snapshots] in await snapshots.refresh(taskID) } }
        return PublicFacadeLease(taskID: taskID) { [weak self, weak value] in self?.release(taskID, holder: value, id: id) }
    }

    private func release(_ taskID: String, holder value: PublicEventHolder?, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let value, holders[taskID] === value, value.roles.removeValue(forKey: id) != nil else { return }
        if value.roles.isEmpty {
            value.reset()
            publishLatest(value)
            value.lease = nil
            // Existing subscriptions retain this cleared holder until cancellation. A later
            // appearance acquires a fresh holder and subscribes again, per VM teardown rules.
            holders.removeValue(forKey: taskID)
        } else { value.lease?.session.setActivityEnabled(value.roles.values.contains(true)) }
    }

    public func observation(for taskID: String) -> EventObservationFrame {
        lock.lock(); defer { lock.unlock() }
        return holders[taskID]?.frame ?? EventObservationFrame(taskID: taskID, scope: Self.unconfiguredScope)
    }

    public func observationPublisher(for taskID: String) -> AnyPublisher<EventObservationFrame, Never> {
        lock.lock(); defer { lock.unlock() }
        let value = holder(taskID)
        return value.frames
.receive(on: DispatchQueue.main)
.compactMap { [weak self, value] envelope in
            guard let self else { return nil }
            lock.lock(); defer { self.lock.unlock() }
            guard value.deliveryGeneration == envelope.generation, value.frame == envelope.frame else { return nil }
            return envelope.frame
        }
.removeDuplicates()
.eraseToAnyPublisher()
    }

    @discardableResult public func requestObservation(action: EventObservationAction, for taskID: String, scope: EventObservationScope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = holders[taskID], value.frame.scope == scope,
              value.roles.values.contains(true), value.frame.history.availableActions.contains(action), let session = value.lease?.session else { return false }
        switch action {
        case .loadEarlier: return session.requestOlder()
        case .retryRead: session.retryObservation()
        case .rebaseWindow, .adoptCurrentSource: session.adoptCurrentActivity()
        }
        return true
    }

    public func requestState(for taskID: String) -> TaskRequestReadState {
        lock.lock(); defer { lock.unlock() }
        return holders[taskID]?.request ?? .notRequested
    }

    public func requestPublisher(for taskID: String) -> AnyPublisher<TaskRequestReadState, Never> {
        lock.lock(); defer { lock.unlock() }
        let value = holder(taskID)
        return value.requests
.receive(on: DispatchQueue.main)
.compactMap { [weak self, value] envelope in
            guard let self else { return nil }
            lock.lock(); defer { self.lock.unlock() }
            guard value.deliveryGeneration == envelope.generation, value.request == envelope.state else { return nil }
            return envelope.state
        }
.removeDuplicates()
.eraseToAnyPublisher()
    }

    public func readRequest(for taskID: String, maxBytes: Int = 65536) {
        lock.lock(); defer { lock.unlock() }
        guard let value = holders[taskID], !value.roles.isEmpty, [65536, 131072].contains(maxBytes) else { return }
        if maxBytes == 131072 {
            if case .failed(_, maxBytes: 131072) = value.request {
                // An explicit retry repeats this same bounded prefix; it does not page further.
            } else {
                guard !value.readMoreUsed, case .received(let prompt, maxBytes: 65536) = value.request,
                      prompt.text != nil, [.available, .previewOnly].contains(prompt.state),
                      prompt.truncated || !prompt.complete || prompt.integrity == .unverified else { return }
                value.readMoreUsed = true
            }
        } else { value.readMoreUsed = false }
        value.promptTask?.cancel()
        let requestID = UUID()
        value.requestID = requestID
        let token = generation
        let lifetime = value.lifetime
        let current: @Sendable () -> Bool = { [weak self, weak value] in
            guard let self, let value else { return false }
            lock.lock(); defer { self.lock.unlock() }
            return generation == token && value.lifetime == lifetime && value.requestID == requestID && !value.roles.isEmpty
        }
        if value.setRequest(.loading(maxBytes: maxBytes)) { publishLatest(value) }
        value.promptTask = Task { [weak self, weak value, prompts] in
            let result = await prompts.read(taskID: taskID, maxBytes: maxBytes, operationIsCurrent: current)
            guard let self, let value else { return }
            lock.withLock {
                guard current(), !Task.isCancelled else { return }
                let changed = switch result {
                case .success(let prompt): value.setRequest(.received(prompt, maxBytes: maxBytes))
                case .failure(let error): value.setRequest(.failed(error, maxBytes: maxBytes))
                }
                if changed { publishLatest(value) }
            }
        }
    }

    /// One pending main delivery per holder, regardless of background page/replay speed.
    private func publishLatest(_ value: PublicEventHolder) {
        guard !value.publicationPending else { return }
        value.publicationPending = true
        publicationDelivery { [weak self, value] in
            guard let self else { return }
            lock.withLock {
                value.publicationPending = false
                let frame = PublicEventHolder.FrameEnvelope(generation: value.deliveryGeneration, frame: value.frame)
                if value.frames.value.generation != frame.generation || value.frames.value.frame != frame.frame { value.frames.send(frame) }
                let request = PublicEventHolder.RequestEnvelope(generation: value.deliveryGeneration, state: value.request)
                if value.requests.value.generation != request.generation || value.requests.value.state != request.state { value.requests.send(request) }
            }
        }
    }

    public var leasedTaskIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(holders.filter { $0.value.roles.values.contains(true) }.map(\.key))
    }
}
