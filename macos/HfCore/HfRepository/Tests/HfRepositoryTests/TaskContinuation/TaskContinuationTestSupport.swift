import Combine
import Foundation
@testable import HfRepository
import Mockable
import MonitorCore

// MARK: - ContinuationLatch

actor ContinuationLatch {
    private var arrived = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var parked: CheckedContinuation<Void, Never>?

    func park() async {
        arrived = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        if !released { await withCheckedContinuation { parked = $0 } }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { observers.append($0) } }
    }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }
}

// MARK: - ContinuationRunner

actor ContinuationRunner: ProcessRunning {
    let latch: ContinuationLatch?
    var commands: [[String]] = []
    var output: ProcessOutput
    var capabilities = ["ctl.v1", "setup.v1", "events.v1", "task-continue.v1", "task-successors.v1"]

    init(output: ProcessOutput = continuationOutput(), latch: ContinuationLatch? = nil) {
        self.output = output
        self.latch = latch
    }

    func setOutput(_ output: ProcessOutput) { self.output = output }
    func setCapabilities(_ values: [String]) { capabilities = values }

    func run(executable _: String, arguments: [String], environment: [String: String], currentDirectory _: String?, timeout _: Double)
        async -> Result<ProcessOutput, ToolError> {
        if arguments.first == "version-info" { return .success(probe(environment)) }
        commands.append(arguments)
        await latch?.park()
        return .success(output)
    }

    private func probe(_ environment: [String: String]) -> ProcessOutput {
        let raw: [String: JSONValue] = [
            "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
            "product_version": .string(HarflowVersion.current), "component": .string("engine"),
            "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
            "contracts": .object([
                "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                "events": .object(["format": .string("harflow.event"), "v": .number(1)])
            ]),
            "capabilities": .array(capabilities.map(JSONValue.string)), "os": .string("darwin"), "architecture": .string("arm64")
        ]
        return stdout(JSONValue.object(raw).rendered())
    }
}

func continuationOutput(task: String? = "accepted", error: String? = nil, exit: Int32 = 0) -> ProcessOutput {
    var raw: [String: JSONValue] = [
        "product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
        "product_version": .string(HarflowVersion.current)
    ]
    if let error {
        raw["error"] = .object(["code": .string(error), "message": .string(error)])
    } else {
        raw["result"] = .object(task.map { ["task_id": .string($0)] } ?? [:])
    }
    return ProcessOutput(exitCode: exit, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "", timedOut: false)
}

// MARK: - ContinuationPages

actor ContinuationPages {
    var answers: [Result<TaskSuccessorPage, ToolError>]
    var cursors: [String?] = []
    let latch: ContinuationLatch?
    let latchAtRead: Int

    init(_ answers: [Result<TaskSuccessorPage, ToolError>] = [], latch: ContinuationLatch? = nil, latchAtRead: Int = 1) {
        self.answers = answers
        self.latch = latch
        self.latchAtRead = latchAtRead
    }

    func read(_ cursor: String?) async throws -> TaskSuccessorPage {
        cursors.append(cursor)
        if cursors.count == latchAtRead { await latch?.park() }
        guard !answers.isEmpty else { throw ToolError.notFound(tool: "fixture", searched: []) }
        return try answers.removeFirst().get()
    }
}

// MARK: - ContinuationTaskList

struct ContinuationTaskList: TaskListRepository {
    let pages: ContinuationPages
    var tasks = [makeTaskInfo("source"), makeTaskInfo("next"), makeTaskInfo("other")]
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
    func successorPage(predecessorTaskID _: String, cursor: String?, runtime _: QualificationRuntimeToken) async throws -> TaskSuccessorPage {
        try await pages.read(cursor)
    }
}

// MARK: - ContinuationHarness

struct ContinuationHarness {
    let runner: ContinuationRunner
    let pages: ContinuationPages
    let selected: LockedBox<CtlClient>
    let actions: TaskActionRepositoryImpl
    let repository: TaskContinuationRepositoryImpl
    let runtime: QualificationRuntimeToken

    init(runner: ContinuationRunner = ContinuationRunner(), pages: ContinuationPages = ContinuationPages(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.runner = runner
        self.pages = pages
        let client = CtlClient(executable: "/fixture/original/ctl", environment: [:], runner: runner)
        let selected = LockedBox(client)
        self.selected = selected
        self.runtime = QualificationRuntimeToken(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { .success(selected.value) }
        let list = ContinuationTaskList(pages: pages)
        self.actions = TaskActionRepositoryImpl(toolEnvironment: tooling, taskListRepository: list, snapshotRepository: NullTaskSnapshotRepository())
        self.repository = TaskContinuationRepositoryImpl(tooling: tooling, taskList: list, actions: actions, now: now)
    }

    func request(_ source: String = "source", conversation: String = "conversation") -> TaskContinuationRequest {
        TaskContinuationRequest(runtime: runtime, conversationID: conversation, sourceTaskID: source)
    }
}

func continuationPage(_ ids: [String] = [], cursor: String? = nil, source: String = "source",
                      overrides: [String: JSONValue] = [:], related: [String] = []) -> TaskSuccessorPage {
    func row(_ id: String) -> JSONValue {
        .object(["task_id": .string(id), "status": .string("completed"), "backend": .string("fixture"),
                 "continuation_of_task_id": .string(source)])
    }
    var raw: [String: JSONValue] = [
        "predecessor_task_id": .string(source), "successor_scope": .string("recorded_tasks"),
        "items": .array(ids.map(row)), "related_headers": .array(related.map(row)),
        "has_more": .bool(cursor != nil), "next_cursor": cursor.map(JSONValue.string) ?? .null,
        "bootstrap_pending": .bool(false), "history_incomplete": .bool(false), "authority_incomplete": .bool(false),
        "counts_complete": .bool(false),
        "catalog_state": .object(["status": .string("ready"), "source": .string("fixture"),
                                  "pending_records": .number(0), "blocked_records": .number(0)])
    ]
    raw.merge(overrides) { _, new in new }
    return TaskSuccessorPage(raw: raw, predecessorTaskID: source)!
}
