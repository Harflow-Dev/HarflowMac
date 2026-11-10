import Combine
import Foundation
import HfUtilities
import MonitorCore

// MARK: - TaskSnapshotRepositoryImpl

public final class TaskSnapshotRepositoryImpl: TaskSnapshotRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository

    @Subjected private var snapshotsValue: [String: TaskInfo] = [:]
    /// Serializes read-modify-write: refreshes run concurrently (a lease's first refresh races the
    /// listing's own loop), and `@Subjected` only makes each single get or set atomic.
    private let mutationLock = NSLock()
    /// The newest refresh started per task, guarded by `mutationLock`. Overlapping refreshes of one
    /// task can answer out of order — a lease's first refresh races the listing's — and a late,
    /// older answer must not replace a newer one (a stale `running` hiding a finished task's
    /// summary, Codex PR review): only the most recently started refresh may publish.
    /// Clock access never takes the snapshot mutation lock or publishes callbacks.
    private let revisionLock = NSLock()
    private var revision: UInt64 = 0
    private var outcomes: [String: TaskSnapshotReadOutcome] = [:]
    private let readChanges = PassthroughSubject<TaskSnapshotReadChange, Never>()
    private var generations: [String: UInt64] = [:]
    /// Guards `batchStatusSupported` — flipped once (never back) when an older ctl answers
    /// `status-batch` with `unsupportedCommand`, so the rest of the session refreshes per id.
    private let batchSupportLock = NSLock()
    private var batchStatusSupported = true

    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public var snapshots: [String: TaskInfo] { snapshotsValue }
    public func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { $snapshotsValue.removeDuplicates().eraseToAnyPublisher() }
    public func snapshot(_ id: String) -> TaskInfo? { snapshotsValue[id] }

    public var readRevision: UInt64 { revisionLock.withLock { revision } }
    public var readOutcomes: [String: TaskSnapshotReadOutcome] { mutationLock.withLock { outcomes } }
    public func readChangesPublisher() -> AnyPublisher<TaskSnapshotReadChange, Never> {
        readChanges.prepend(.updated).eraseToAnyPublisher()
    }

    public func refresh(_ id: String) async {
        let generation = beginRefresh(id)
        guard case .success(let client) = toolEnvironment.ctl() else {
            complete(id, generation, task: nil)
            return
        }
        await refresh(id, client: client, generation: generation)
    }

    private func refresh(_ id: String, client: CtlClient, generation: UInt64? = nil) async {
        let generation = generation ?? beginRefresh(id)
        switch await client.status(id) {
        case .success(let info): complete(id, generation, task: info)
        case .failure(let error): complete(id, generation, task: nil, removeCached: error.refusalCode == "unknown_task")
        }
    }

    public func refresh(ids: [String]) async {
        var seen = Set<String>()
        let bounded = Array(ids.filter { seen.insert($0).inserted }.prefix(100))
        guard !bounded.isEmpty else { return }
        guard isBatchStatusSupported else {
            for id in bounded { await refresh(id) }
            return
        }
        let attempts = Dictionary(uniqueKeysWithValues: bounded.map { ($0, beginRefresh($0)) })
        guard case .success(let client) = toolEnvironment.ctl() else {
            for id in bounded { complete(id, attempts[id]!, task: nil) }
            return
        }
        switch await client.statusBatch(ids: bounded) {
        case .success(let batch):
            let indexed = Dictionary(batch.tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { _, new in new })
            for id in bounded {
                complete(id, attempts[id]!, task: indexed[id], removeCached: batch.errors[id]?.code == "unknown_task")
            }
        case .failure(let error):
            if case .unsupportedCommand = error {
                markBatchStatusUnsupported()
                for id in bounded { await refresh(id) }
            } else {
                for id in bounded { complete(id, attempts[id]!, task: nil) }
            }
        }
    }

    private func markBatchStatusUnsupported() {
        batchSupportLock.lock()
        batchStatusSupported = false
        batchSupportLock.unlock()
    }

    private var isBatchStatusSupported: Bool {
        batchSupportLock.lock()
        defer { batchSupportLock.unlock() }
        return batchStatusSupported
    }

    private func beginRefresh(_ id: String) -> UInt64 {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let next = revisionLock.withLock { revision += 1; return revision }
        generations[id] = next
        return next
    }

    private func complete(_ id: String, _ generation: UInt64, task: TaskInfo?, removeCached: Bool = false) {
        let admitted = mutationLock.withLock {
            guard generations[id] == generation else { return false }
            outcomes[id] = TaskSnapshotReadOutcome(revision: generation, task: task)
            var next = snapshotsValue
            if let task {
                if !next[id].isEquivalent(to: task) { next[id] = task }
            } else if removeCached { next[id] = nil }
            if !next.isEquivalent(to: snapshotsValue) { snapshotsValue = next }
            return true
        }
        if admitted { readChanges.send(.updated) }
    }

    public func evict(keeping ids: Set<String>) {
        let evictionRevision = mutationLock.withLock {
            let next = revisionLock.withLock { revision += 1; return revision }
            generations = generations.filter { ids.contains($0.key) }
            outcomes = outcomes.filter { ids.contains($0.key) }
            snapshotsValue = snapshotsValue.filter { ids.contains($0.key) }
            return next
        }
        readChanges.send(.evicted(revision: evictionRevision, keeping: ids))
    }
}
