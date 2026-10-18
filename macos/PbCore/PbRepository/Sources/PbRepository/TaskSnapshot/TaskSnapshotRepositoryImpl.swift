import Combine
import Foundation
import MonitorCore
import PbUtilities

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

    public func refresh(_ id: String) async {
        // A ctl-not-found failure is a no-op — never clears or overwrites the stale snapshot
        // (F4-12's "ctl-not-found is a no-op").
        guard case .success(let client) = toolEnvironment.ctl() else { return }
        await refresh(id, client: client)
    }

    private func refresh(_ id: String, client: CtlClient) async {
        let generation = beginRefresh(id)
        switch await client.status(id) {
        case .success(let info):
            mutate(ifCurrent: id, generation) { snapshots in
                if !snapshots[id].isEquivalent(to: info) { snapshots[id] = info }
            }
        case .failure(let error):
            if error.refusalCode == "unknown_task" { mutate(ifCurrent: id, generation) { $0[id] = nil } }
        }
    }

    public func refresh(ids: [String]) async {
        guard !ids.isEmpty else { return }
        guard case .success(let client) = toolEnvironment.ctl() else { return }
        var seen = Set<String>()
        let bounded = Array(ids.filter { seen.insert($0).inserted }.prefix(100))
        guard isBatchStatusSupported else {
            for id in bounded { await refresh(id, client: client) }
            return
        }
        // Generations are bumped before the call, so a whole-batch failure discards any older
        // in-flight single refresh for these ids until the next pass; that is accepted.
        let generations = Dictionary(uniqueKeysWithValues: bounded.map { ($0, beginRefresh($0)) })
        switch await client.statusBatch(ids: bounded) {
        case .success(let batch):
            applyBatch(batch, ids: bounded, generations: generations)
        case .failure(let error):
            if case .unsupportedCommand = error {
                markBatchStatusUnsupported()
                for id in bounded { await refresh(id, client: client) }
            }
            // Any other whole-command failure leaves every snapshot exactly as it is.
        }
    }

    /// Applies each id's batch outcome behind its own generation guard: a returned snapshot
    /// stores, `unknown_task` evicts, anything else retains — exactly as `refresh(_:)`.
    private func applyBatch(_ batch: StatusBatchResult, ids: [String], generations: [String: UInt64]) {
        let indexed = Dictionary(batch.tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { _, new in new })
        for id in ids {
            guard let generation = generations[id] else { continue }
            if let info = indexed[id] {
                mutate(ifCurrent: id, generation) { snapshots in
                    if !snapshots[id].isEquivalent(to: info) { snapshots[id] = info }
                }
            } else if batch.errors[id]?.code == "unknown_task" {
                mutate(ifCurrent: id, generation) { $0[id] = nil }
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
        let next = (generations[id] ?? 0) &+ 1
        generations[id] = next
        return next
    }

    private func mutate(ifCurrent id: String, _ generation: UInt64, _ change: (inout [String: TaskInfo]) -> Void) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard generations[id] == generation else { return }
        var next = snapshotsValue
        change(&next)
        // An equivalent update is not a change: keep the stored value (its `duration_seconds`
        // drift carries no state for a running task with a start time) so an unchanged poll
        // publishes nothing at all.
        guard !next.isEquivalent(to: snapshotsValue) else { return }
        snapshotsValue = next
    }

    public func evict(keeping ids: Set<String>) {
        mutate { snapshots in snapshots = snapshots.filter { ids.contains($0.key) } }
    }

    private func mutate(_ change: (inout [String: TaskInfo]) -> Void) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        var next = snapshotsValue
        change(&next)
        snapshotsValue = next
    }
}
