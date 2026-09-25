import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - TaskListRepository

/// `polybridge-ctl list`, refresh coalescing, titles, the FSEvents throttle, the safety poll, and
/// `detail()` precedence — everything in `AppModel` from `start()` through `connectionLine`
/// (`AppModel.swift:55-223,474-483`).
@Mockable
public protocol TaskListRepository: Sendable {

    var tasks: [TaskInfo] { get }
    var listError: ToolError? { get }
    var hasListed: Bool { get }
    var titles: [String: String] { get }

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never>
    func hasListedPublisher() -> AnyPublisher<Bool, Never>
    func titlesPublisher() -> AnyPublisher<[String: String], Never>

    /// Discovery → first list → watcher start, exactly once (MS-LIST-1/F4-01). A second call is a
    /// no-op.
    func start()

    /// Refresh coalescing: a refresh already in flight arms one more pass rather than running
    /// concurrently (MS-LIST-4).
    func refresh() async

    /// Called by the Settings screen after `SettingsRepository.setToolDirectory` — triggers a
    /// refresh only; the login-PATH/`uv` probes never rerun (F4-05).
    func settingsChanged()

    func title(_ taskID: String) -> String
    func task(_ id: String) -> TaskInfo?

    /// The fullest view of a task: listing status wins over a differing snapshot status, else the
    /// snapshot, else the listing; nil once the task has left the listing (the C.8 fix).
    func detail(_ id: String) -> TaskInfo?

    func runningInSubtrees(of ids: [String]) -> [String]
    var runningCount: Int { get }
    var connectionLine: String { get }
}

// MARK: - NullTaskListRepository

public struct NullTaskListRepository: TaskListRepository {
    public init() {}
    public var tasks: [TaskInfo] { [] }
    public var listError: ToolError? { nil }
    public var hasListed: Bool { false }
    public var titles: [String: String] { [:] }
    public func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { Just([]).eraseToAnyPublisher() }
    public func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { Just(nil).eraseToAnyPublisher() }
    public func hasListedPublisher() -> AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    public func titlesPublisher() -> AnyPublisher<[String: String], Never> { Just([:]).eraseToAnyPublisher() }
    public func start() {}
    public func refresh() async {}
    public func settingsChanged() {}
    public func title(_ taskID: String) -> String { "Task \(taskID.prefix(8))" }
    public func task(_: String) -> TaskInfo? { nil }
    public func detail(_: String) -> TaskInfo? { nil }
    public func runningInSubtrees(of _: [String]) -> [String] { [] }
    public var runningCount: Int { 0 }
    public var connectionLine: String { "connecting…" }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global task-list repository.
    @GlobalEntry var taskListRepository: any TaskListRepository = NullTaskListRepository()
}
