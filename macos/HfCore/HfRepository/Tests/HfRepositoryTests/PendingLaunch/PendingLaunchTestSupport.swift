import Foundation
@testable import HfRepository
import Mockable
import MonitorCore

// MARK: - PendingLaunchRunner

actor PendingLaunchRunner: ProcessRunning {
    var pageAnswers: [ProcessOutput]
    var lookupAnswers: [ProcessOutput]
    var cancelAnswer = pendingEnvelope(["status": .string("accepted")])
    var historyAnswer = pendingEnvelope(["items": .array([]), "next_cursor": .null, "has_more": .bool(false), "bootstrap_pending": .bool(false)])
    var statuses: [String: ProcessOutput] = [:]
    var statusLatchID: String?
    var statusAnswer = stdout(JSONValue.object([
        "product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
        "product_version": .string(HarflowVersion.current),
        "task": .object(["task_id": .string("target"), "status": .string("running")])
    ])
.rendered())
    var calls: [[String]] = []
    var latch: ContinuationLatch?
    var probeLatch: ContinuationLatch?
    var latchCommand = "task-pending-status"
    var capabilities = ["ctl.v1", "setup.v1", "events.v1", "task-pending-launch.v1", "task-cancel-cascade.v1", "task-continue.v1", "task-successors.v1"]

    init(pages: [ProcessOutput] = [pendingEnvelope(pendingPage())], lookups: [ProcessOutput] = [pendingEnvelope(pendingLookup())]) {
        self.pageAnswers = pages
        self.lookupAnswers = lookups
    }

    func setStatus(_ row: [String: JSONValue], id: String) { statuses[id] = pendingStatus(row) }
    func setStatusOutput(_ output: ProcessOutput, id: String) { statuses[id] = output }
    func setStatusLatch(_ value: ContinuationLatch?, id: String) { latch = value; latchCommand = "status"; statusLatchID = id }
    func setHistory(_ rows: [[String: JSONValue]]) {
        historyAnswer = pendingEnvelope(["items": .array(rows.map(JSONValue.object)), "next_cursor": .null, "has_more": .bool(false),
                                         "bootstrap_pending": .bool(false), "counts_complete": .bool(true), "total_active_count": .number(0)])
    }

    func setPages(_ values: [ProcessOutput]) { pageAnswers = values }
    func setLookups(_ values: [ProcessOutput]) { lookupAnswers = values }
    func setLatch(_ value: ContinuationLatch?, command: String = "task-pending-status") { latch = value; latchCommand = command }
    func setProbeLatch(_ value: ContinuationLatch?) { probeLatch = value }
    func setCancel(_ value: ProcessOutput) { cancelAnswer = value }
    func setCapabilities(_ values: [String]) { capabilities = values }
    func run(executable _: String, arguments: [String], environment: [String: String], currentDirectory _: String?,
             timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        calls.append(arguments)
        if arguments.first == "version-info" {
            let response = probe(environment)
            await probeLatch?.park()
            return .success(response)
        }
        let answer: ProcessOutput
        switch arguments.first {
        case "task-pending-page": answer = pageAnswers.count > 1 ? pageAnswers.removeFirst() : pageAnswers[0]
        case "task-pending-status": answer = lookupAnswers.count > 1 ? lookupAnswers.removeFirst() : lookupAnswers[0]
        case "cancel": answer = cancelAnswer
        case "status": answer = statuses[arguments.last ?? ""] ?? statusAnswer
        case "task-list-page": answer = historyAnswer
        case "run": answer = pendingEnvelope(["task_id": .string("target")])
        case "continue": answer = pendingEnvelope([:])
        default: return .failure(.unsupportedCommand(tool: "harflow-ctl", command: arguments.first ?? "", detail: "fixture"))
        }
        if arguments.first == latchCommand, statusLatchID == nil || arguments.last == statusLatchID { await latch?.park() }
        return .success(answer)
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

func pendingEnvelope(_ result: [String: JSONValue], error: String? = nil) -> ProcessOutput {
    var raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
                                    "product_version": .string(HarflowVersion.current)]
    if let error {
        raw["error"] = .object(["code": .string(error), "message": .string(error)])
    } else {
        raw["result"] = .object(result)
    }
    return ProcessOutput(exitCode: error == nil ? 0 : 1, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "", timedOut: false)
}

func pendingItem(_ id: String = "target", state: String = "waiting_for_resources",
                 generation: String = String(repeating: "a", count: 32)) -> [String: JSONValue] {
    ["task_id": .string(id), "disposition": .string("pending"), "cancel_support": .string("supported"),
     "launch": .object(["generation": .string(generation), "state": .string(state), "title": .string("Pending"),
                         "backend": .null, "repo_path": .null, "created_at": .null, "not_started_reason": .null,
                         "lineage": .object([:]), "resource_names": .array([]), "metadata_truncated": .bool(false)])]
}

func pendingLookup(disposition: String = "pending", state: String = "waiting_for_resources",
                   generation: String = String(repeating: "a", count: 32)) -> [String: JSONValue] {
    var result = pendingItem(state: state, generation: generation)
    result["disposition"] = .string(disposition)
    result["scope"] = .string(TaskPendingLaunchWire.scope)
    result["observed_at"] = .string("fixture")
    return result
}

func pendingPage(_ ids: [String] = [], cursor: String? = nil, revision: String = String(repeating: "b", count: 64),
                 overrides: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var result: [String: JSONValue] = ["scope": .string(TaskPendingLaunchWire.scope), "observed_at": .string("fixture"),
                                       "namespace_revision": .string(revision), "namespace_complete": .bool(true),
                                       "coverage": .string(cursor == nil ? "complete" : "unknown"), "invalid_name_count": .number(0),
                                       "examined_count": .number(Double(max(ids.count, cursor == nil ? 0 : 1))),
                                       "has_more": .bool(cursor != nil), "next_cursor": cursor.map(JSONValue.string) ?? .null,
                                       "bound": .null, "items": .array(ids.map { .object(pendingItem($0)) })]
    result.merge(overrides) { _, new in new }
    return result
}

struct PendingLaunchHarness {
    let runner: PendingLaunchRunner
    let owner: PendingLaunchRepositoryImpl
    let selected: LockedBox<CtlClient>
    let tools: MockToolEnvironmentRepository
    let actions: TaskActionRepositoryImpl
    init(runner: PendingLaunchRunner = PendingLaunchRunner(), list: any TaskListRepository = NullTaskListRepository(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.runner = runner
        let client = CtlClient(executable: "/fixture/pending/ctl", environment: [:], runner: runner)
        selected = LockedBox(client)
        let selected = selected
        self.tools = MockToolEnvironmentRepository()
        given(tools).tasksDirectory.willReturn("/fixture/state/tasks")
        given(tools).ctl().willProduce { .success(selected.value) }
        self.actions = TaskActionRepositoryImpl(toolEnvironment: tools, taskListRepository: list, snapshotRepository: NullTaskSnapshotRepository())
        self.owner = PendingLaunchRepositoryImpl(tooling: tools, taskList: list, actions: actions,
                                            recovery: NullStateRecoveryRepository(), now: now)
    }
}

func pendingCancelResult(basis: String) -> [String: JSONValue] {
    ["task_id": .string("target"), "status": .string("cancelled"),
     "cascade": .object(["observation": .object([
         "scope": .string("recorded_tasks_and_pending_launches"), "observed_at": .string("fixture"),
         "coverage": .string("complete"), "truncated": .bool(false),
         "items": .array([.object(["task_id": .string("target"), "state": .string("stopped"),
                                   "basis": .string(basis), "status": .string("cancelled")])])
     ])])]
}

func pendingStatus(_ row: [String: JSONValue]) -> ProcessOutput {
    stdout(JSONValue.object([
        "product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
        "product_version": .string(HarflowVersion.current), "task": .object(row)
    ])
.rendered())
}
