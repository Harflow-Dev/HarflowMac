import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

// MARK: - CountingRunner

/// Counts every process launch, including the `version-info` handshake `CtlClient` runs before each command.
private final class CountingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [[String]] = []
    private let delegate: PositiveCtlRunner

    init(_ delegate: PositiveCtlRunner) { self.delegate = delegate }

    var launches: [[String]] { lock.withLock { launched } }
    func reset() { lock.withLock { launched = [] } }

    func run(
        executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double
    ) async -> Result<ProcessOutput, ToolError> {
        lock.withLock { launched.append(arguments) }
        return await delegate.run(executable: executable, arguments: arguments, environment: environment,
                                  currentDirectory: currentDirectory, timeout: timeout)
    }
}

// MARK: - NeedsYouLaunchBudgetTests

@Suite struct NeedsYouLaunchBudgetTests {
    private func document(_ result: [String: JSONValue]) -> ProcessOutput {
        var object: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
                                           "product_version": .string("0.0.1")]
        object["result"] = .object(result)
        return stdout(JSONValue.object(object).rendered())
    }

    private func page(_ items: [[String: JSONValue]]) -> [String: JSONValue] {
        ["items": .array(items.map(JSONValue.object)), "has_more": .bool(false), "bootstrap_pending": .bool(false),
         "next_cursor": .null, "total_active_count": .number(Double(items.count))]
    }

    @Test func givenAHeavyEngine_whenPassesRun_thenEveryPassStaysWithinTheProcessLaunchBudget() async throws {
        // given — many needy roots, many approval tasks and caller-owned approvals (capability probe included).
        let headers = (0 ..< 40).map { rootHeader(String(format: "w%02d", $0)) }
        let tasks: [[String: JSONValue]] = (0 ..< 40).map { index in
            ["task_id": .string("t\(index)"), "status": .string("running"), "backend": .string("claude"),
             "approval_summary": .object(["awaiting_decision_count": .number(1), "pending_count": .number(1)])]
        }
        let detail = approval(owner: "caller").raw
        let stub = StubProcessRunner { call in
            switch call.arguments.first ?? "" {
            case "workflow-list-page": return .success(document(page(headers)))
            case "task-list-page": return .success(document(page(tasks)))
            case "workflow-status":
                let id = call.arguments.last ?? ""
                return .success(document(treeRoot(id, selected: "d", inputs: [inputEntry(run: id, decision: "d")])))
            case "status-batch":
                let ids = (call.arguments.first { $0.hasPrefix("--task-ids=") } ?? "").dropFirst("--task-ids=".count).split(separator: ",")
                let entries = tasks.filter { ids.contains(Substring($0["task_id"]?.stringValue ?? "")) }
                var object: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
                                                   "product_version": .string("0.0.1"), "tasks": .array(entries.map(JSONValue.object)),
                                                   "errors": .object([:])]
                object["v"] = .number(1)
                return .success(stdout(JSONValue.object(object).rendered()))
            case "approval-list":
                let task = (call.arguments.first { $0.hasPrefix("--task-id=") } ?? "").dropFirst("--task-id=".count)
                var row = detail
                row["task_id"] = .string(String(task))
                return .success(document(["requests": .array([.object(row)]), "total": .number(1)]))
            case "approval-get":
                var row = detail
                row["task_id"] = .string(call.arguments.last ?? "")
                return .success(document(row))
            default: return .success(stdout("{}"))
            }
        }
        let runner = CountingRunner(PositiveCtlRunner(stub))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let engine = CtlNeedsYouEngine(toolEnvironment: toolEnvironment, workflows: WorkflowRepositoryImpl(toolEnvironment: toolEnvironment))
        let sut = NeedsYouRepositoryImpl(engine: engine, toolEnvironment: toolEnvironment, scheduler: CapturingScheduler(),
                                         visibility: FakeMonitorVisibility(), install: readyInstall())
        // when
        var perPass: [Int] = []
        for _ in 0 ..< 6 {
            runner.reset()
            await sut.runPass()
            perPass.append(runner.launches.count)
        }
        // then
        #expect(perPass.allSatisfy { $0 <= NeedsYouCore.invocationBudget }, "launches per pass: \(perPass)")
        #expect(perPass.allSatisfy { $0 > 2 })
        #expect(!sut.snapshot.items.isEmpty)
    }
}
