import Combine
import Foundation
import HfUtilities
import MonitorCore

// MARK: - ResourceSlotsRepositoryImpl

/// Synchronous deduplicated snapshots over an actor-owned observation lifecycle.
public final class ResourceSlotsRepositoryImpl: ResourceSlotsRepository, @unchecked Sendable {
    @Subjected private var value = ResourceSlotsSnapshot()
    private let observer: ResourceSlotsObserver

    public init(tooling: any ToolEnvironmentRepository, scheduler: any Scheduling) {
        let state = Subjected(wrappedValue: ResourceSlotsSnapshot())
        _value = state
        self.observer = ResourceSlotsObserver(tooling: tooling, scheduler: scheduler) { snapshot in
            if state.wrappedValue != snapshot { state.wrappedValue = snapshot }
        }
    }

    public var snapshot: ResourceSlotsSnapshot { value }
    public func snapshotPublisher() -> AnyPublisher<ResourceSlotsSnapshot, Never> { $value.removeDuplicates().eraseToAnyPublisher() }
    public func acquireObservation() async -> UUID { await observer.acquire() }
    public func releaseObservation(_ lease: UUID) async { await observer.release(lease) }
    public func refresh() async { await observer.requestRefresh(manual: true) }
    public func runtimeChanged() async { await observer.runtimeChanged() }
}

// MARK: - ResourceSlotsObserver

private actor ResourceSlotsObserver {
    private struct OwnerMetadata: Sendable {
        let checkedAt: Date
        let title: String?
        let qualified: Bool
    }

    private let tooling: any ToolEnvironmentRepository
    private let scheduler: any Scheduling
    private let publish: @Sendable (ResourceSlotsSnapshot) -> Void
    private var leases: Set<UUID> = []
    private var generation: UInt64 = 0
    private var runtime: QualificationRuntimeToken?
    private var state = ResourceSlotsSnapshot()
    private var polling: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var flight: UUID?
    private var gate: ResourceSlotsReadGate?
    private var queued = false
    private var workflowMetadata: [String: OwnerMetadata] = [:]
    private var metadataCursor = 0
    private var taskMetadata: [String: OwnerMetadata] = [:]
    private var taskMetadataCursor = 0

    init(tooling: any ToolEnvironmentRepository, scheduler: any Scheduling,
         publish: @escaping @Sendable (ResourceSlotsSnapshot) -> Void) {
        self.tooling = tooling
        self.scheduler = scheduler
        self.publish = publish
    }

    func acquire() -> UUID {
        let lease = UUID()
        leases.insert(lease)
        _ = synchronizeRuntime()
        if polling == nil {
            let scheduler = scheduler
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await scheduler.wait(for: 5) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.requestRefresh(manual: false)
                }
            }
        }
        requestRefresh(manual: false)
        return lease
    }

    func release(_ lease: UUID) {
        guard leases.remove(lease) != nil, leases.isEmpty else { return }
        generation &+= 1
        gate?.revoke()
        polling?.cancel()
        polling = nil
        work?.cancel()
        queued = false
        state.isRefreshing = false
        emit()
    }

    func runtimeChanged() {
        _ = synchronizeRuntime()
        if !leases.isEmpty { requestRefresh(manual: false) }
    }

    /// The binding is rechecked on acquisition, observable readiness changes and each read boundary.
    private func synchronizeRuntime() -> Result<CtlClient, ToolError> {
        let selected = tooling.ctl()
        let current = try? selected.get()
        let token = current.map { QualificationRuntimeToken(client: $0) }
        if token != runtime {
            runtime = token
            generation &+= 1
            gate?.revoke()
            workflowMetadata = [:]
            taskMetadata = [:]
            metadataCursor = 0
            taskMetadataCursor = 0
            state = ResourceSlotsSnapshot()
            if case .failure(let error) = selected { state = failure(error, retained: nil) }
            emit()
        }
        return selected
    }

    func requestRefresh(manual: Bool) {
        guard !leases.isEmpty else { return }
        _ = synchronizeRuntime()
        if manual, state.data != nil {
            state.isRefreshing = true
            emit()
        }
        guard work == nil else { queued = true; return }
        queued = false
        let id = UUID()
        flight = id
        work = Task { [weak self] in
            guard let self else { return }
            await read()
            await finished(id)
        }
    }

    private func finished(_ id: UUID) {
        guard flight == id else { return }
        work = nil
        flight = nil
        gate = nil
        if queued, !leases.isEmpty { requestRefresh(manual: false) }
    }

    private func current(_ expected: UInt64, token: QualificationRuntimeToken) -> Bool {
        let selected = synchronizeRuntime()
        let matches = (try? selected.get()).map { QualificationRuntimeToken(client: $0) } == token
        if !matches, !leases.isEmpty { queued = true }
        return !Task.isCancelled && !leases.isEmpty && generation == expected && matches
    }

    private func read() async {
        let selected = synchronizeRuntime()
        guard !leases.isEmpty, !Task.isCancelled else { return }
        var client: CtlClient
        switch selected {
        case .failure(let error):
            state = failure(error, retained: state.data)
            emit()
            return
        case .success(let value): client = value
        }
        let token = QualificationRuntimeToken(client: client)
        let expected = generation
        let readGate = ResourceSlotsReadGate()
        gate = readGate
        let tooling = tooling
        let previousCheck = client.operationIsCurrent
        client.operationIsCurrent = {
            previousCheck() && readGate.isActive
                && (try? tooling.ctl().get()).map { QualificationRuntimeToken(client: $0) } == token
        }
        let inventory = await client.resourceInventory()
        guard current(expected, token: token) else { return }
        switch inventory {
        case .failure(let error):
            state = failure(error, retained: state.data)
            emit()
        case .success(let entries):
            let phase = await client.phaseSlotsStatus()
            guard current(expected, token: token) else { return }
            switch phase {
            case .failure(let error):
                state = failure(error, retained: state.data)
                emit()
            case .success(let status):
                let owners = await metadata(entries: entries, status: status, client: client)
                guard current(expected, token: token) else { return }
                state = ResourceSlotsSnapshot(phase: .ready, data: ResourceSlotsData(inventory: entries, phaseStatus: status, owners: owners))
                emit()
            }
        }
    }

    private func failure(_ error: ToolError, retained: ResourceSlotsData?) -> ResourceSlotsSnapshot {
        let phase: ResourceSlotsSnapshot.Phase = switch error {
        case .unsupportedCommand, .unsupportedVersion: .unsupported
        default: error.refusalCode == "phase_slots_not_enabled" ? .notEnabled : .unavailable
        }
        return ResourceSlotsSnapshot(phase: phase, data: retained, error: error, isStale: retained != nil)
    }

    /// Runtime-bound metadata uses at most one task batch and one workflow batch per pass.
    private func metadata(
        entries: [ResourceInventoryEntry], status: PhaseSlotsStatus, client: CtlClient
    ) async -> [ResourceSlotOwner: ResourceSlotOwnerMetadata] {
        guard metadataIsCurrent(client) else { return [:] }
        var owners = Set(entries.flatMap { ($0.holders + $0.queue).map(\.owner) })
        owners.formUnion(status.leases.flatMap { ($0.blockers ?? []).map(\.owner) })
        let now = scheduler.now()
        await enrichTasks(Set(owners.compactMap(\.metadataTaskID)), now: now, client: client)
        guard metadataIsCurrent(client) else { return [:] }
        await enrichWorkflows(Set(owners.compactMap(\.metadataWorkflowRunID)), now: now, client: client)
        guard metadataIsCurrent(client) else { return [:] }
        return Dictionary(uniqueKeysWithValues: owners.map { ($0, ownerMetadata($0)) })
    }

    private func metadataIsCurrent(_ client: CtlClient) -> Bool {
        runtime == QualificationRuntimeToken(client: client) && !leases.isEmpty && !Task.isCancelled && client.operationIsCurrent()
    }

    private func metadataBatch(
        ids: Set<String>, cache: [String: OwnerMetadata], now: Date, cursor: inout Int
    ) -> [String] {
        let pending = ids.filter { id in
            guard let cached = cache[id] else { return true }
            return now.timeIntervalSince(cached.checkedAt) >= 60
        }
.sorted()
        guard !pending.isEmpty else { return [] }
        let offset = cursor % pending.count
        let rotated = Array(pending[offset...]) + Array(pending[..<offset])
        // Both public metadata commands accept at most 100 IDs; never silently lose leftovers.
        let batch = Array(rotated.prefix(100))
        cursor = (offset + batch.count) % pending.count
        return batch
    }

    private func enrichTasks(_ ids: Set<String>, now: Date, client: CtlClient) async {
        taskMetadata = taskMetadata.filter { ids.contains($0.key) }
        let batch = metadataBatch(ids: ids, cache: taskMetadata, now: now, cursor: &taskMetadataCursor)
        guard !batch.isEmpty else { return }
        let response = await client.statusBatchOutcomes(ids: batch)
        guard metadataIsCurrent(client) else { return }
        for id in batch { taskMetadata[id] = OwnerMetadata(checkedAt: now, title: nil, qualified: false) }
        guard case .success(let response) = response else { return }
        for id in batch {
            guard let outcome = response[id], case .success(let task) = outcome, task.taskID == id else { continue }
            taskMetadata[id] = OwnerMetadata(checkedAt: now, title: task.raw["title"]?.stringValue, qualified: true)
        }
    }

    private func enrichWorkflows(_ ids: Set<String>, now: Date, client: CtlClient) async {
        workflowMetadata = workflowMetadata.filter { ids.contains($0.key) }
        let batch = metadataBatch(ids: ids, cache: workflowMetadata, now: now, cursor: &metadataCursor)
        guard !batch.isEmpty else { return }
        let page = await client.workflowHistoryPage(runIDs: batch)
        guard metadataIsCurrent(client) else { return }
        for id in batch { workflowMetadata[id] = OwnerMetadata(checkedAt: now, title: nil, qualified: false) }
        guard case .success(let page) = page, !page.bootstrapPending, !page.authorityIncomplete else { return }
        for item in page.items {
            guard let id = item["workflow_run_id"]?.stringValue, batch.contains(id),
                  item["needs_direct_lookup"]?.boolValue != true, item["kind"]?.stringValue == "workflow" else { continue }
            workflowMetadata[id] = OwnerMetadata(checkedAt: now, title: item["name"]?.stringValue, qualified: true)
        }
    }

    private func ownerMetadata(_ owner: ResourceSlotOwner) -> ResourceSlotOwnerMetadata {
        var title: String?
        var destination: ResourceSlotOwnerMetadata.Destination?
        if let id = owner.metadataTaskID, let metadata = taskMetadata[id], metadata.qualified {
            title = metadata.title
            destination = .task(id)
        } else if let id = owner.metadataWorkflowRunID, let metadata = workflowMetadata[id], metadata.qualified {
            title = metadata.title
            destination = .workflowRun(runID: id, activationID: owner.activationID)
        }
        return ResourceSlotOwnerMetadata(owner: owner, title: title, destination: destination)
    }

    private func emit() { publish(state) }
}

// MARK: - ResourceSlotsReadGate

/// Synchronous launch cancellation shared by the actor and CtlClient compatibility suspension boundary.
private final class ResourceSlotsReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
