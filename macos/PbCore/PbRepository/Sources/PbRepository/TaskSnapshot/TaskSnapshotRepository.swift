import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskSnapshotRepository

/// Per-task `polybridge-ctl status` snapshots, exactly as `AppModel.snapshots`/`refreshSnapshot`
/// (`AppModel.swift:215-223`, = F4-12): success stores; an `unknown_task` refusal clears the
/// snapshot; any other failure — including ctl not being locatable — keeps the stale snapshot.
@Mockable
public protocol TaskSnapshotRepository: Sendable {

    var snapshots: [String: TaskInfo] { get }
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func snapshot(_ id: String) -> TaskInfo?

    func refresh(_ id: String) async

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
    public func evict(keeping _: Set<String>) {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global task-snapshot repository.
    @GlobalEntry var taskSnapshotRepository: any TaskSnapshotRepository = NullTaskSnapshotRepository()
}
