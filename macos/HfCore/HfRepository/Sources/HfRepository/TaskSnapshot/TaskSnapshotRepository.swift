import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

/// Latest completed public status attempt, independent of the retained display cache.
public struct TaskSnapshotReadOutcome: Equatable, Sendable {
    public let revision: UInt64
    public let task: TaskInfo?
    public init(revision: UInt64, task: TaskInfo?) {
        self.revision = revision
        self.task = task
    }
}

/// Disposable invalidation; subscribers reread the synchronous outcome snapshot.
public enum TaskSnapshotReadChange: Sendable {
    case updated
    case evicted(revision: UInt64, keeping: Set<String>)
}

// MARK: - TaskSnapshotRepository

/// Per-task `harflow-ctl status` snapshots, exactly as `AppModel.snapshots`/`refreshSnapshot`
/// (`AppModel.swift:215-223`, = F4-12): success stores; an `unknown_task` refusal clears the
/// snapshot; any other failure — including ctl not being locatable — keeps the stale snapshot.
@Mockable
public protocol TaskSnapshotRepository: Sendable {

    /// Global clock advanced before every read attempt and eviction. Implementations must
    /// provide this getter without taking a snapshot-state lock or invoking callbacks.
    var readRevision: UInt64 { get }
    /// Latest admitted completion for each retained task.
    var readOutcomes: [String: TaskSnapshotReadOutcome] { get }
    func readChangesPublisher() -> AnyPublisher<TaskSnapshotReadChange, Never>

    var snapshots: [String: TaskInfo] { get }
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func snapshot(_ id: String) -> TaskInfo?

    func refresh(_ id: String) async

    /// Refreshes up to 100 snapshots in **one** `harflow-ctl status-batch` process instead of
    /// one `status` per id. Per-id outcomes follow `refresh(_:)`: a returned snapshot stores, an
    /// `unknown_task` error evicts, any other per-id error retains the stale snapshot. An older
    /// ctl without the command falls back to per-id refreshes for the rest of the session; any
    /// other whole-command failure retains every snapshot as it is.
    func refresh(ids: [String]) async

    /// Drops every snapshot whose task id is not in `ids` — called after a successful listing
    /// (`AppModel.swift:158`).
    func evict(keeping ids: Set<String>)
}

// MARK: - NullTaskSnapshotRepository

public struct NullTaskSnapshotRepository: TaskSnapshotRepository {
    public init() {}
    public var snapshots: [String: TaskInfo] { [:] }
    public func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { Just([:]).eraseToAnyPublisher() }
    public func snapshot(_: String) -> TaskInfo? { nil }
    public func refresh(_: String) async {}
    public func refresh(ids _: [String]) async {}
    public func evict(keeping _: Set<String>) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global task-snapshot repository.
    @GlobalEntry var taskSnapshotRepository: any TaskSnapshotRepository = NullTaskSnapshotRepository()
}

public extension TaskSnapshotRepository {
    var readRevision: UInt64 { 0 }
    var readOutcomes: [String: TaskSnapshotReadOutcome] { [:] }
    func readChangesPublisher() -> AnyPublisher<TaskSnapshotReadChange, Never> { Just(.updated).eraseToAnyPublisher() }
}
