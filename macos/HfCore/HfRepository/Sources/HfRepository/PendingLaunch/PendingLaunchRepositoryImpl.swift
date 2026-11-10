import Combine
import Foundation
import HfUtilities
import MonitorCore

// MARK: - PendingLaunchRepositoryImpl

/// Shared owner. State locks never span dependency calls, awaits or publications.
public final class PendingLaunchRepositoryImpl: PendingLaunchRepository, @unchecked Sendable {
    let tooling: any ToolEnvironmentRepository
    let taskList: any TaskListRepository
    let actions: any TaskActionRepository
    let recovery: any StateRecoveryRepository
    let reader: PendingLaunchInventoryReader
    let lock = NSLock()
    private let publicationLock = NSLock()
    private var publicationPending = false
    private var publicationDraining = false
    private var lastPublished: PendingLaunchSnapshot
    private let published: CurrentValueSubject<PendingLaunchSnapshot, Never>
    var value = PendingLaunchSnapshot()
    var epoch = UUID()
    var leases: Set<PendingLaunchReadLease> = []
    var selections: [PendingLaunchReadLease: PendingLaunchSelection] = [:]
    var selectionGates: [UUID: PendingLaunchAdmissionGate] = [:]
    var lookupBusyLeases: Set<PendingLaunchReadLease> = []
    var inventoryReads = 0
    var inventoryGate: PendingLaunchAdmissionGate?
    var confirmations: [UUID: PendingLaunchStopConfirmation] = [:]
    var confirmationSelections: [UUID: PendingLaunchSelection] = [:]
    var commandGates: [UUID: PendingLaunchAdmissionGate] = [:]
    var attemptCosts: [UUID: Int] = [:]
    var runtimeSubscription: AnyCancellable?

    public init(tooling: any ToolEnvironmentRepository, taskList: any TaskListRepository,
                actions: any TaskActionRepository, recovery: any StateRecoveryRepository,
                now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.tooling = tooling
        self.taskList = taskList
        self.actions = actions
        self.recovery = recovery
        self.reader = PendingLaunchInventoryReader(now: now)
        let initial = PendingLaunchSnapshot()
        self.value = initial
        self.epoch = initial.runtimeIdentity
        self.published = CurrentValueSubject(initial)
        self.lastPublished = initial
    }

    public var snapshot: PendingLaunchSnapshot { lock.withLock { value } }
    public func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { published.removeDuplicates().eraseToAnyPublisher() }

    /// Inline subscription, deliberately without a queue hop: A→B→A must revoke old work.
    public func bindRuntimeChanges(_ publisher: AnyPublisher<ManagedRuntimeState, Never>) {
        runtimeSubscription = publisher.dropFirst().sink { [weak self] _ in self?.runtimeChanged() }
    }

    func publish() {
        let start = publicationLock.withLock {
            publicationPending = true
            guard !publicationDraining else { return false }
            publicationDraining = true
            return true
        }
        guard start else { return }
        while takePublicationRequest() {
            let next = snapshot
            let changed = publicationLock.withLock {
                guard lastPublished != next else { return false }
                lastPublished = next
                return true
            }
            // Reentrant/concurrent mutations only request another wave. No listener can receive
            // a newer nested wave followed by this older one, and no owner lock spans callbacks.
            if changed { published.send(next) }
        }
    }

    private func takePublicationRequest() -> Bool {
        publicationLock.withLock {
            guard publicationPending else { publicationDraining = false; return false }
            publicationPending = false
            return true
        }
    }

    public func acquireReadLease() -> PendingLaunchReadLease? {
        let lease: PendingLaunchReadLease? = lock.withLock {
            guard leases.count < 8 else { return nil }
            let lease = PendingLaunchReadLease()
            leases.insert(lease)
            return lease
        }
        if let lease { Task { [weak self] in await self?.refresh(lease: lease) } }
        return lease
    }

    public func releaseReadLease(_ lease: PendingLaunchReadLease) {
        _ = bindSelection(taskID: nil, lease: lease)
        let gate: PendingLaunchAdmissionGate? = lock.withLock {
            leases.remove(lease)
            guard leases.isEmpty else { return nil }
            let gate = inventoryGate
            inventoryGate = nil
            value.inventory.isRefreshing = false
            return gate
        }
        gate?.revoke()
        publish()
    }

    public func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection? {
        let old = lock.withLock { selections[lease].flatMap { selectionGates[$0.id] } }
        old?.revoke()
        return lock.withLock {
            guard leases.contains(lease) else { return nil }
            if let previous = selections.removeValue(forKey: lease) {
                selectionGates.removeValue(forKey: previous.id)
                let stale = confirmationSelections.filter { $0.value == previous }.map(\.key)
                for id in stale { confirmations.removeValue(forKey: id); confirmationSelections.removeValue(forKey: id) }
            }
            guard let taskID, TaskPendingLaunchWire.isFullID(taskID) else { return nil }
            let selection = PendingLaunchSelection(taskID: taskID, lease: lease)
            selections[lease] = selection
            selectionGates[selection.id] = PendingLaunchAdmissionGate()
            return selection
        }
    }

    public func runtimeChanged() {
        let gates = lock.withLock {
            let gates = Array(selectionGates.values) + Array(commandGates.values) + [inventoryGate].compactMap(\.self)
            epoch = UUID()
            selections.removeAll(); selectionGates.removeAll(); confirmations.removeAll(); confirmationSelections.removeAll()
            inventoryGate = nil
            value.runtimeIdentity = epoch
            value.currentRuntime = nil
            value.inventory = PendingLaunchInventory()
            value.lookups.removeAll()
            return gates
        }
        // No owner lock while revoking gates: a history commit takes gate→history, and a read
        // commit takes gate→owner. Old confirmations cannot be admitted after the epoch advance.
        gates.forEach { $0.revoke() }
        publish()
        let visible = lock.withLock { leases.first }
        if let visible { Task { [weak self] in await self?.refresh(lease: visible) } }
    }

    func context(selection: PendingLaunchSelection) -> (UUID, PendingLaunchAdmissionGate)? {
        lock.withLock {
            guard leases.contains(selection.lease), selections[selection.lease] == selection,
                  let gate = selectionGates[selection.id] else { return nil }
            return (epoch, gate)
        }
    }

    func client(gate: PendingLaunchAdmissionGate, runtime: QualificationRuntimeToken? = nil) throws -> CtlClient {
        var client = try runtime?.boundClient(tooling: tooling) ?? tooling.ctl().get()
        let captured = QualificationRuntimeToken(client: client)
        if let previous = snapshot.currentRuntime, previous != captured {
            runtimeChanged()
            throw QualificationSessionError.runtimeChanged
        }
        let original = client.operationIsCurrent
        let tooling = tooling
        client.operationIsCurrent = {
            guard gate.isCurrent, original(), let current = try? tooling.ctl().get() else { return false }
            return QualificationRuntimeToken(client: current) == captured
        }
        return client
    }

    public func refresh(lease: PendingLaunchReadLease) async {
        let gate = PendingLaunchAdmissionGate()
        let capturedEpoch: UUID? = lock.withLock {
            guard leases.contains(lease), inventoryGate == nil else { return nil }
            guard inventoryReads < 2 else {
                value.inventory.failure = .capacity
                value.inventory.isStale = true
                value.inventory.completedCheck = false
                return nil
            }
            inventoryReads += 1
            inventoryGate = gate
            value.inventory.isRefreshing = true
            return epoch
        }
        guard let capturedEpoch else { publish(); return }
        defer { lock.withLock { inventoryReads -= 1 } }
        publish()
        let result: PendingLaunchInventoryReader.Read
        do {
            let client = try client(gate: gate)
            lock.withLock { if epoch == capturedEpoch { value.currentRuntime = QualificationRuntimeToken(client: client) } }
            result = await reader.read(client: client)
            guard client.operationIsCurrent() else { finishInventory(gate: gate, epoch: capturedEpoch, result: .init(failure: .superseded)); return }
        } catch { result = .init(failure: failure(error)) }
        finishInventory(gate: gate, epoch: capturedEpoch, result: result)
    }

    private func finishInventory(gate: PendingLaunchAdmissionGate, epoch captured: UUID, result: PendingLaunchInventoryReader.Read) {
        let current = gate.isCurrent
        lock.withLock {
            guard inventoryGate === gate else { return }
            inventoryGate = nil
            guard epoch == captured else { return }
            value.inventory.isRefreshing = false
            guard current, result.failure != .superseded else { return }
            if result.complete {
                value.inventory.rows = result.rows
            } else {
                // Retain healthy prior evidence. A new unsupported row cannot erase its neighbor.
                let oldIDs = Set(value.inventory.rows.map(\.taskID))
                let additions = result.rows.filter { !oldIDs.contains($0.taskID) }.prefix(max(0, 4096 - oldIDs.count))
                var retainedBytes = value.inventory.rows.reduce(0) { $0 + JSONValue.object($1.raw).rendered().utf8.count }
                for item in additions {
                    let cost = JSONValue.object(item.raw).rendered().utf8.count
                    guard retainedBytes + cost <= 8 * 1024 * 1024 else { break }
                    value.inventory.rows.append(item)
                    retainedBytes += cost
                }
            }
            value.inventory.completedCheck = result.complete
            value.inventory.isStale = !result.complete
            value.inventory.failure = result.failure
        }
        publish()
    }

    private func admitLookup(_ selection: PendingLaunchSelection) -> PendingLaunchFailure? {
        lock.withLock {
            guard leases.contains(selection.lease), selections[selection.lease] == selection else { return .superseded }
            guard !lookupBusyLeases.contains(selection.lease) else { return .busy }
            guard lookupBusyLeases.count < 8 else { return .capacity }
            lookupBusyLeases.insert(selection.lease)
            return nil
        }
    }

    public func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup {
        if let refusal = admitLookup(selection) { return .init(selection: selection, value: nil, failure: refusal) }
        defer { _ = lock.withLock { lookupBusyLeases.remove(selection.lease) } }
        guard let (_, previous) = context(selection: selection) else { return .init(selection: selection, value: nil, failure: .superseded) }
        previous.revoke()
        let gate = PendingLaunchAdmissionGate()
        let captured: UUID? = lock.withLock {
            guard selections[selection.lease] == selection else { return nil }
            selectionGates[selection.id] = gate
            return epoch
        }
        guard let captured else { return .init(selection: selection, value: nil, failure: .superseded) }
        let result: PendingLaunchLookup
        do {
            let client = try client(gate: gate)
            let response = await client.taskPendingStatus(taskID: selection.taskID)
            guard client.operationIsCurrent(), !Task.isCancelled else { return .init(selection: selection, value: nil, failure: .superseded) }
            switch response {
            case .success(let lookup): result = .init(selection: selection, value: lookup, failure: nil)
            case .failure(let error): result = .init(selection: selection, value: nil, failure: .tool(error))
            }
        } catch { result = .init(selection: selection, value: nil, failure: failure(error)) }
        let accepted = gate.withCurrent { lock.withLock {
            guard epoch == captured, selections[selection.lease] == selection else { return false }
            var next = value.lookups.filter { $0.selection.lease != selection.lease }
            next.append(result)
            guard next.count <= 128, next.reduce(0, { $0 + Self.lookupCost($1) }) <= 2 * 1024 * 1024 else { return false }
            value.lookups = next
            return true
        } } == true
        guard accepted else { return .init(selection: selection, value: nil, failure: gate.isCurrent ? .capacity : .superseded) }
        if case .tool(let error) = result.failure { recovery.report(error) }
        publish()
        return result
    }

    public func resolveRecorded(selection: PendingLaunchSelection) async -> PendingLaunchRecordedResult {
        let read = await check(selection: selection)
        guard read.failure == nil, read.value?.item.disposition == .recorded else { return .failed(read.failure ?? .changed) }
        guard let (_, gate) = context(selection: selection), gate.isCurrent else { return .failed(.superseded) }
        do {
            let client = try client(gate: gate)
            let runtime = QualificationRuntimeToken(client: client)
            let task = try await taskList.admitRecorded(selection.taskID, runtime: runtime, gate: gate)
            guard gate.isCurrent, client.operationIsCurrent(), context(selection: selection) != nil else { return .failed(.superseded) }
            return .admitted(task)
        } catch { return .failed(failure(error)) }
    }

    func failure(_ error: Error) -> PendingLaunchFailure {
        if let error = error as? ToolError { return .tool(error) }
        if let error = error as? PendingRecordedAdmissionFailure { return .recordedAdmission(error) }
        return .superseded
    }

    static func lookupCost(_ lookup: PendingLaunchLookup) -> Int {
        256 + (lookup.value.map { JSONValue.object($0.raw).rendered().utf8.count } ?? 0)
            + (lookup.failure.map { String(describing: $0).utf8.count } ?? 0)
    }
}
