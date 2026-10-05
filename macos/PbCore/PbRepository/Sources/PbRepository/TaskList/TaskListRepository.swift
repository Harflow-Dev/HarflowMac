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

    var historyState: HistoryLoadingState { get }
    func historyStatePublisher() -> AnyPublisher<HistoryLoadingState, Never>
    func loadMoreHistory() async
    func resolve(_ id: String) async -> TaskInfo?
    func conversationPage(sessionID: String, cursor: String?, limit: Int) async throws -> TaskHistoryPage

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

    /// Like `refresh()`, but waits for — and reports the result of — a pass that starts **after**
    /// this call, rather than firing-and-forgetting. Used by the install operation's completion
    /// barrier, so a validated install only reports success once the listing has actually refreshed.
    func refreshAndWait() async -> Result<Void, ToolError>

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

public struct HistoryLoadingState: Equatable, Sendable {
    public var nextCursor: String?
    public var hasMore = false
    public var bootstrapPending = false
    public var historyIncomplete = false
    public var authorityIncomplete = false
    public var countsComplete = false
    public var isLoading = false
    public var error: ToolError?
    public init() {}
}

public extension TaskListRepository {
    var historyState: HistoryLoadingState { HistoryLoadingState() }
    func historyStatePublisher() -> AnyPublisher<HistoryLoadingState, Never> { Just(historyState).eraseToAnyPublisher() }
    func loadMoreHistory() async {}
    func resolve(_ id: String) async -> TaskInfo? { task(id) }
    func conversationPage(sessionID: String, cursor: String?) async throws -> TaskHistoryPage {
        try await conversationPage(sessionID: sessionID, cursor: cursor, limit: 100)
    }

    func conversationPage(sessionID: String, cursor: String?, limit: Int) async throws -> TaskHistoryPage {
        throw ToolError.unsupportedCommand(tool: "polybridge-ctl", command: "task-list-page", detail: "Conversation pages unavailable")
    }
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
    public func refreshAndWait() async -> Result<Void, ToolError> { .success(()) }
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
