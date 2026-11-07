import Foundation
@testable import HfRepository
import Mockable
import MonitorCore

// MARK: - ChangesHarness

/// A repository over a scripted ctl runner. Answers are consumed in order for `task-changes` commands.
struct ChangesHarness {
    enum Answer {
        case page([String], total: Int, cursor: String? = nil, task: String = "task", captureState: String = "available")
        case pending(String)
        case refusal(String, data: [String: JSONValue]? = nil)
        case chunk(String, offset: Int, total: Int, cursor: String? = nil, path: String = "a.txt")
        case chunkBytes([UInt8], offset: Int, total: Int, cursor: String? = nil)
    }

    let runner: StubProcessRunner
    let repository: TaskChangesRepositoryImpl
    let recovery: StateRecoveryRepositoryImpl

    var commands: [[String]] { runner.calls.filter { $0.arguments.first == "task-changes" }.map(\.arguments) }

    init(_ answers: [Answer], capability: LockedBox<Bool> = LockedBox(true), environment: [String: String] = [:],
         selected: LockedBox<CtlClient>? = nil, clock: ChangesFakeClock? = nil, onServe: (@Sendable (Int) -> Void)? = nil) {
        let served = LockedBox(0)
        let runner = StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] { return .success(Self.probe(call.environment, capability: capability.value)) }
            let index = served.value
            served.mutate { $0 += 1 }
            let output = Self.output(answers[min(index, answers.count - 1)])
            onServe?(index + 1)
            return .success(output)
        }
        self.runner = runner
        let client = CtlClient(executable: "/fixture/ctl", environment: environment, runner: runner)
        selected?.mutate { $0 = client }
        let tools = MockToolEnvironmentRepository()
        if let selected {
            given(tools).ctl().willProduce { .success(selected.value) }
        } else {
            given(tools).ctl().willReturn(.success(client))
        }
        let recovery = StateRecoveryRepositoryImpl(toolEnvironment: tools)
        self.recovery = recovery
        if let clock {
            self.repository = TaskChangesRepositoryImpl(toolEnvironment: tools, recovery: recovery, now: { clock.now })
        } else {
            self.repository = TaskChangesRepositoryImpl(toolEnvironment: tools, recovery: recovery, now: { .now })
        }
    }

    // MARK: Documents

    private static func probe(_ environment: [String: String], capability: Bool) -> ProcessOutput {
        let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
        let capabilities = ["ctl.v1", "setup.v1", "events.v1"] + (capability ? ["task-changes.v1"] : [])
        let raw: [String: JSONValue] = [
            "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
            "product_version": .string(HarflowVersion.current), "component": .string("engine"), "state_root": .string(root),
            "contracts": .object([
                "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                "events": .object(["format": .string("harflow.event"), "v": .number(1)])
            ]),
            "capabilities": .array(capabilities.map(JSONValue.string)), "os": .string("darwin"), "architecture": .string("arm64")
        ]
        return stdout(JSONValue.object(raw).rendered())
    }

    private static func envelope(_ body: [String: JSONValue], exit: Int32) -> ProcessOutput {
        var raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"),
                                        "product_version": .string(HarflowVersion.current), "v": .number(1)]
        raw.merge(body) { _, new in new }
        return ProcessOutput(exitCode: exit, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "", timedOut: false)
    }

    private static func output(_ answer: Answer) -> ProcessOutput {
        switch answer {
        case .page(let rows, let total, let cursor, let task, let captureState):
            return envelope(["result": listing(rows: rows, total: total, cursor: cursor, task: task, captureState: captureState, captureReason: nil)], exit: 0)
        case .pending(let reason):
            return envelope(["result": listing(rows: [], total: 0, cursor: nil, task: "task", captureState: "pending", captureReason: reason,
                                               repositories: [])], exit: 0)
        case .refusal(let code, let data):
            var error: [String: JSONValue] = ["code": .string(code), "message": .string(code)]
            if let data { error["data"] = .object(data) }
            return envelope(["error": .object(error)], exit: 1)
        case .chunk(let text, let offset, let total, let cursor, let path):
            return envelope(["result": chunk(text: .string(text), b64: .null, returned: text.utf8.count, offset: offset, total: total, cursor: cursor,
                                             path: path)], exit: 0)
        case .chunkBytes(let bytes, let offset, let total, let cursor):
            return envelope(["result": chunk(text: .null, b64: .string(Data(bytes).base64EncodedString()), returned: bytes.count, offset: offset,
                                             total: total, cursor: cursor, path: "a.txt")], exit: 0)
        }
    }

    private static func row(_ path: String) -> JSONValue {
        .object(["path": .string(path), "path_bytes_b64": .null, "path_truncated": .bool(false), "old_path": .null, "status": .string("modified"),
                 "additions": .number(1), "deletions": .number(0), "binary": .bool(false),
                 "content": .object(["state": .string("available"), "reason": .null, "bytes": .number(4)])])
    }

    private static func scope(rows: [String], total: Int, working: Bool) -> JSONValue {
        var scope: [String: JSONValue] = ["state": .string("available"), "reason": .null, "row_count": .number(Double(total)),
                                          "rows_truncated": .bool(false), "observed_at": .string("2026-10-14T17:45:50+00:00"),
                                          "rows": .array(rows.map(row))]
        if working {
            scope["counts_and_patch_separate"] = .bool(true)
            scope["unmerged_unknown"] = .bool(false)
            scope["reported_conflicts"] = .object(["names": .array([]), "truncated": .bool(false)])
        }
        return .object(scope)
    }

    // swiftlint:disable:next function_parameter_count
    private static func listing(rows: [String], total: Int, cursor: String?, task: String, captureState: String, captureReason: String?,
                                repositories: [JSONValue]? = nil) -> JSONValue {
        let repository: JSONValue = .object([
            "repository_root": .string("/workspace/repo"), "worktree": .string("/workspace/repo"), "git_common_dir": .string("/workspace/repo/.git"),
            "base_commit": .string(String(repeating: "a", count: 40)), "base_provenance": .string("dispatch"),
            "head_commit": .string(String(repeating: "b", count: 40)), "observed_at": .string("2026-10-14T17:45:50+00:00"),
            "baseline_dirty": .bool(false), "attribution": .string(TaskChangesRepositoryEntry.attribution), "fields_truncated": .bool(false),
            "state": .string("available"), "reason": .null,
            "scopes": .object(["committed_range": scope(rows: rows, total: total, working: false),
                               "working_tree": scope(rows: [], total: 0, working: true)])
        ])
        return .object([
            "task_id": .string(task), "mode": .string("list"),
            "capture": .object(["state": .string(captureState), "reason": captureReason.map(JSONValue.string) ?? .null]),
            "repositories": .array(repositories ?? [repository]), "limit": .number(500), "has_more": .bool(cursor != nil),
            "next_cursor": cursor.map(JSONValue.string) ?? .null, "observed_at": .string("2026-10-14T17:46:40+00:00")
        ])
    }

    // swiftlint:disable:next function_parameter_count
    private static func chunk(text: JSONValue, b64: JSONValue, returned: Int, offset: Int, total: Int, cursor: String?, path: String) -> JSONValue {
        .object([
            "task_id": .string("task"), "mode": .string("text"), "capture": .object(["state": .string("available"), "reason": .null]),
            "repository_root": .string("/workspace/repo"), "scope": .string("working_tree"), "path": .string(path), "path_bytes_b64": .null,
            "path_truncated": .bool(false), "status": .string("modified"), "additions": .number(1), "deletions": .number(0), "binary": .bool(false),
            "content": .object(["state": .string("available"), "reason": .null, "bytes": .number(Double(total))]), "text": text, "text_b64": b64,
            "offset": .number(Double(offset)), "returned_bytes": .number(Double(returned)), "total_bytes": .number(Double(total)),
            "has_more": .bool(cursor != nil), "next_cursor": cursor.map(JSONValue.string) ?? .null,
            "observed_at": .string("2026-10-14T17:46:40+00:00")
        ])
    }
}

// MARK: - ChangesFakeClock

/// An injected clock for the read deadline.
final class ChangesFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(seconds: Int) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
}
