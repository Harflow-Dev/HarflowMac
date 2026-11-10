import Combine
import Foundation
import HfRepository
import Mockable
import MonitorCore

// MARK: - HostedContinuationLatch

actor HostedContinuationLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    nonisolated let arrived = HostedContinuationFlag()

    func park() async {
        arrived.value = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - HostedContinuationFlag

final class HostedContinuationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - HostedContinuationCtl

/// Fake public process boundary; Continue still traverses the real shared invocation owner.
actor HostedContinuationCtl: ProcessRunning {
    let latch = HostedContinuationLatch()
    private(set) var continueCount = 0
    var result: Result<ProcessOutput, ToolError>

    init(result: Result<ProcessOutput, ToolError> = .success(HostedContinuationCtl.response(task: "accepted-session"))) {
        self.result = result
    }

    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        switch arguments.first {
        case "version-info": return .success(probe(environment))
        case "continue":
            continueCount += 1
            await latch.park()
            return result
        default: return .failure(.unsupportedCommand(tool: "fixture ctl", command: arguments.first ?? "", detail: "Unexpected hosted command"))
        }
    }

    nonisolated static func response(task: String? = nil, reason: String? = nil) -> ProcessOutput {
        var raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"),
            "v": .number(1), "product_version": .string(HarflowVersion.current)]
        if let reason {
            raw["error"] = .object(["code": .string("refused"), "message": .string(reason)])
        } else {
            raw["result"] = .object(["task_id": .string(task ?? "accepted-session")])
        }
        return ProcessOutput(exitCode: reason == nil ? 0 : 1, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }

    private func probe(_ environment: [String: String]) -> ProcessOutput {
        let raw: [String: JSONValue] = [
            "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
            "product_version": .string(HarflowVersion.current), "component": .string("engine"),
            "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
            "contracts": .object([
                "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                "events": .object(["format": .string("harflow.event"), "v": .number(1)])]),
            "capabilities": .array(["ctl.v1", "setup.v1", "events.v1", "task-continue.v1", "task-successors.v1"].map(JSONValue.string)),
            "os": .string("darwin"), "architecture": .string("arm64")]
        return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }
}

// MARK: - HostedContinuationPages

final class HostedContinuationPages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<TaskSuccessorPage, ToolError>
    private var count = 0
    private var sources: [String: Result<TaskSuccessorPage, ToolError>] = [:]
    func set(_ result: Result<TaskSuccessorPage, ToolError>, for source: String) { lock.withLock { sources[source] = result } }
    var readCount: Int { lock.withLock { count } }
    func read(_ source: String) throws -> TaskSuccessorPage {
        try lock.withLock {
            count += 1
            return try (sources[source] ?? stored).get()
        }
    }

    init() { self.stored = .success(Self.page()) }
    var result: Result<TaskSuccessorPage, ToolError> {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    static func page(_ ids: [String] = [], source: String = "abc12345") -> TaskSuccessorPage {
        let rows: [JSONValue] = ids.map { .object(["task_id": .string($0), "status": .string("running"),
            "backend": .string("claude"), "continuation_of_task_id": .string(source)]) }
        return TaskSuccessorPage(raw: ["predecessor_task_id": .string(source), "successor_scope": .string("recorded_tasks"),
            "items": .array(rows), "related_headers": .array([]), "has_more": .bool(false), "next_cursor": .null,
            "bootstrap_pending": .bool(false), "history_incomplete": .bool(false), "authority_incomplete": .bool(false),
            "counts_complete": .bool(false), "catalog_state": .object(["status": .string("ready"), "source": .string("fixture"),
                "pending_records": .number(0), "blocked_records": .number(0)])], predecessorTaskID: source)!
    }
}

// MARK: - HostedContinuationList

struct HostedContinuationList: TaskListRepository {
    let pages: HostedContinuationPages
    let tasks: [TaskInfo]
    var listError: ToolError? { nil }
    var hasListed: Bool { true }
    var titles: [String: String] { [:] }
    var runningCount: Int { 0 }
    var connectionLine: String { "" }
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { Just(tasks).eraseToAnyPublisher() }
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { Just(nil).eraseToAnyPublisher() }
    func hasListedPublisher() -> AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    func titlesPublisher() -> AnyPublisher<[String: String], Never> { Just([:]).eraseToAnyPublisher() }
    func start() {}
    func refresh() async {}
    func refreshAndWait() async -> Result<Void, ToolError> { .success(()) }
    func settingsChanged() {}
    func title(_ id: String) -> String { id }
    func task(_ id: String) -> TaskInfo? { tasks.first { $0.taskID == id } }
    func detail(_ id: String) -> TaskInfo? { task(id) }
    func runningInSubtrees(of _: [String]) -> [String] { [] }
    func successorPage(predecessorTaskID source: String, cursor _: String?, runtime _: QualificationRuntimeToken) async throws -> TaskSuccessorPage {
        try pages.read(source)
    }
}
