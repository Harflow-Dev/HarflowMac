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

    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public var snapshots: [String: TaskInfo] { snapshotsValue }
    public func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { $snapshotsValue.eraseToAnyPublisher() }
    public func snapshot(_ id: String) -> TaskInfo? { snapshotsValue[id] }

    public func refresh(_ id: String) async {
        // A ctl-not-found failure is a no-op — never clears or overwrites the stale snapshot
        // (F4-12's "ctl-not-found is a no-op").
        guard case .success(let client) = toolEnvironment.ctl() else { return }
        switch await client.status(id) {
        case .success(let info):
            mutate { $0[id] = info }
        case .failure(let error):
            if error.refusalCode == "unknown_task" { mutate { $0[id] = nil } }
        }
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
