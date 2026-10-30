import Combine
import Foundation
@testable import HfRepository
import Mockable
import MonitorCore

// MARK: - FakeNeedsYouEngine

/// A scripted engine that records every invocation, so tests can assert the per-pass budget.
final class FakeNeedsYouEngine: NeedsYouEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var headers: [[String: JSONValue]] = []
    var statuses: [String: [String: JSONValue]] = [:]
    var failingStatuses: Set<String> = []
    var tasks: [TaskInfo] = []
    var taskBatchFails = false
    var approvalRows: [String: [CallerApprovalRequest]] = [:]
    var approvalDetails: [String: CallerApprovalRequest] = [:]
    var capability = true
    var pageSize = 100
    var resumeError: ToolError?
    var respondResult: Result<CallerApprovalRequest, ToolError>?
    var resumes: [(root: String, decision: String?, text: String, attempts: Int?)] = []
    var workflowPageFails = false
    var approvalPageSize = 1000
    var approvalPageOverride: (@Sendable (String?) -> CallerApprovalPage)?
    var capabilityFails = false

    var calls: [String] { lock.withLock { log } }
    func resetCalls() { lock.withLock { log = [] } }
    private func record(_ name: String) { lock.withLock { log.append(name) } }

    private func page(_ all: [[String: JSONValue]], cursor: String?) -> [String: JSONValue] {
        let start = cursor.flatMap(Int.init) ?? 0
        let slice = Array(all.dropFirst(start).prefix(pageSize))
        let more = start + slice.count < all.count
        return ["items": .array(slice.map(JSONValue.object)), "has_more": .bool(more), "bootstrap_pending": .bool(false),
                "next_cursor": more ? .string("\(start + slice.count)") : .null, "total_active_count": .number(Double(all.count))]
    }

    func workflowPage(cursor: String?) async throws -> HistoryPage {
        record("workflowPage")
        if workflowPageFails { throw ToolError.timedOut(tool: "harflow-ctl", seconds: 1) }
        return HistoryPage(raw: page(headers, cursor: cursor))!
    }

    func workflowStatus(_ runID: String) async throws -> WorkflowMonitorStatus {
        record("status:\(runID)")
        guard !failingStatuses.contains(runID), let raw = statuses[runID] else { throw ToolError.timedOut(tool: "harflow-ctl", seconds: 1) }
        return WorkflowMonitorStatus(raw)
    }

    func taskPage(cursor: String?) async throws -> TaskHistoryPage {
        record("taskPage")
        return TaskHistoryPage(raw: page(tasks.map(\.raw), cursor: cursor))!
    }

    func taskStatuses(_ ids: [String]) async throws -> [String: Result<TaskInfo, ToolError>] {
        record("batch")
        if taskBatchFails { throw ToolError.unsupportedCommand(tool: "harflow-ctl", command: "status-batch", detail: "") }
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, tasks.first { $0.taskID == id }.map { .success($0) } ?? .failure(.refused(code: "unknown_task", message: "")))
        })
    }

    func approvalPage(taskID: String, cursor: String?) async throws -> CallerApprovalPage {
        record("approvalList:\(taskID)")
        if let approvalPageOverride { return approvalPageOverride(cursor) }
        let rows = approvalRows[taskID] ?? []
        let start = cursor.flatMap(Int.init) ?? 0
        let slice = Array(rows.dropFirst(start).prefix(approvalPageSize))
        let more = start + slice.count < rows.count
        return CallerApprovalPage(requests: slice, nextCursor: more ? "\(start + slice.count)" : nil, total: rows.count)
    }

    func approvalDetail(taskID: String, requestID: String) async throws -> CallerApprovalRequest {
        record("approvalGet:\(requestID)")
        guard let detail = approvalDetails[requestID] else { throw ToolError.timedOut(tool: "harflow-ctl", seconds: 1) }
        return detail
    }

    func supportsMonitorApprovalResponses() async throws -> Bool {
        record("capability")
        if capabilityFails { throw ToolError.timedOut(tool: "harflow-ctl", seconds: 1) }
        return capability
    }

    func resume(root: String, decisionID: String?, text: String, additionalAttempts: Int?) async throws {
        record("resume:\(root)")
        lock.withLock { resumes.append((root, decisionID, text, additionalAttempts)) }
        if let resumeError { throw resumeError }
    }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        record("respond:\(request.id)")
        return try (respondResult ?? .success(request)).get()
    }
}

// MARK: - Builders

func rootHeader(_ id: String, name: String = "Release", status: String = "needs_input", kind: String = "delegation",
                parent: String? = nil) -> [String: JSONValue] {
    var object: [String: JSONValue] = ["workflow_run_id": .string(id), "name": .string(name), "status": .string(status), "kind": .string(kind)]
    if let parent { object["parent_workflow_run_id"] = .string(parent) }
    return object
}

func interaction(owner: String = "caller", caller: String = "dead", available: Bool = true, handover: Bool = false) -> JSONValue {
    .object(["owner": .string(owner), "caller_state": .string(caller), "monitor_available": .bool(available), "reason": .string("note"),
             "handover": handover ? .object(["timestamp": .number(10), "reason": .string("pid_absent"), "previous_owner": .string("caller"),
                                             "responder": .string("monitor"), "action": .string("resume")]) : .null])
}

func controls(resume: Bool = true, attempts: Bool = true) -> JSONValue {
    .object(["resume": .object(["allowed": .bool(resume), "reason": .string("")]),
             "additional_attempts": .object(["allowed": .bool(attempts), "reason": .string("")])])
}

func inputEntry(run: String, decision: String, question: String = "Which target?", since: Double = 100, path: [String]? = nil,
                kind: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "workflow_run_id": .string(run), "workflow_name": .string("Name \(run)"), "node_id": .string("n"), "node_title": .string("Node"),
        "path": .array((path ?? [run]).map(JSONValue.string)), "decision_id": .string(decision), "question": .string(question),
        "question_items": .array([]), "waiting_since": .number(since), "optional_review_skip_available": .bool(false)
    ]
    if let kind { object["kind"] = .string(kind) }
    return .object(object)
}

func treeRoot(_ id: String, status: String = "needs_input", state: JSONValue? = nil, selected: String? = nil, inputs: [JSONValue] = [],
              attention: [JSONValue] = [], controls control: JSONValue? = nil, extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
    var object: [String: JSONValue] = [
        "workflow_run_id": .string(id), "name": .string("Release"), "status": .string(status),
        "interaction_state": state ?? interaction(), "monitor_controls": control ?? controls(),
        "pending_inputs": .array(inputs), "pending_attention": .array(attention)
    ]
    if let selected { object["input_decision_id"] = .string(selected) }
    for (key, value) in extra { object[key] = value }
    return object
}

func approval(task: String = "t1", id: String = "r1", owner: String = "monitor", revision: Int = 1, complete: Bool = true,
              command: String = "ls") -> CallerApprovalRequest {
    var raw: [String: JSONValue] = [
        "request_id": .string(id), "task_id": .string(task), "action_digest": .string("d"), "interaction_owner": .string(owner),
        "owner_revision": .number(Double(revision)), "generation": .string("g"), "disposition": .string("pending"),
        "delivery": .string("pending"), "execution_outcome": .string("unknown"), "complete": .bool(complete),
        "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970), "task_title": .string("Task title"),
        "created_at": .number(50)
    ]
    if complete { raw["action"] = .object(["tool_name": .string("Bash"), "input": .object(["command": .string(command)])]) }
    return CallerApprovalRequest(raw: raw)
}

func awaitingTask(_ id: String, awaiting: Int = 1, extra: [String: JSONValue] = [:]) -> TaskInfo {
    var summary: [String: JSONValue] = ["awaiting_decision_count": .number(Double(awaiting)), "pending_count": .number(Double(awaiting))]
    for (key, value) in extra { summary[key] = value }
    return TaskInfo(.object(["task_id": .string(id), "status": .string("running"), "backend": .string("claude"),
                             "approval_summary": .object(summary)]))!
}

func readyInstall(_ state: CurrentValueSubject<RuntimeSetupState, Never> = CurrentValueSubject(.ready)) -> MockInstallRepository {
    let install = MockInstallRepository()
    given(install).setupState.willProduce { state.value }
    given(install).setupStatePublisher().willReturn(state.eraseToAnyPublisher())
    return install
}

func makeSUT(
    _ engine: FakeNeedsYouEngine, scheduler: CapturingScheduler = CapturingScheduler(), visibility: FakeMonitorVisibility = FakeMonitorVisibility(),
    install: MockInstallRepository = readyInstall()
) -> NeedsYouRepositoryImpl {
    NeedsYouRepositoryImpl(engine: engine, toolEnvironment: NullToolEnvironmentRepository(), scheduler: scheduler, visibility: visibility, install: install)
}
