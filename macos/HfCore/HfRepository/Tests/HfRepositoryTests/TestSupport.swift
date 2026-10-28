import Foundation
@testable import HfRepository
import MonitorCore
import Testing

/// Explicit v1 event fixture helper for positive repository tests.
func currentEventFixture(_ text: String) -> String {
    guard var object = JSONValue.parse(Data(text.utf8))?.objectValue else {
        Issue.record("positive event fixture is not valid JSON")
        return text
    }
    object["product"] = object["product"] ?? .string("harflow")
    object["format"] = object["format"] ?? .string("harflow.event")
    object["product_version"] = object["product_version"] ?? .string("0.0.1")
    return JSONValue.object(object).rendered()
}

/// Builds a `TaskInfo` fixture the same way `MonitorCoreTests/LineageTests.swift` does.
func makeTaskInfo(
    _ id: String,
    status: String = "completed",
    backend: String = "claude",
    repoPath: String = "",
    spawnedBy: String? = nil,
    depth: Int? = nil,
    group: String? = nil
) -> TaskInfo {
    var object: [String: JSONValue] = [
        "task_id": .string(id), "status": .string(status), "backend": .string(backend),
        "repo_path": .string(repoPath),
        "depth": .number(Double(depth ?? (spawnedBy == nil ? 0 : 1))),
        "started_at": .string("2026-09-25T10:00:00+00:00")
    ]
    if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
    if let group { object["group"] = .string(group) }
    return TaskInfo(.object(object))!
}

/// A `ProcessRunning` stub, mirroring `MonitorCoreTests/TestSupport.swift`'s `RecordingRunner`:
/// records every call and answers from a fixed or per-call closure, with no real process spawned.
final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]

        init(executable: String, arguments: [String], environment: [String: String] = [:]) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }

        static func == (lhs: Call, rhs: Call) -> Bool {
            lhs.executable == rhs.executable && lhs.arguments == rhs.arguments
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var allCalls: [Call] { calls }

    let answer: @Sendable (Call) -> Result<ProcessOutput, ToolError>

    init(answer: @escaping @Sendable (Call) -> Result<ProcessOutput, ToolError>) {
        self.answer = answer
    }

    convenience init(output: ProcessOutput) {
        self.init { _ in .success(output) }
    }

    /// Explicit positive-operation fixture: answer the v1 runtime handshake before returning the
    /// supplied command result. Raw negative tests continue to use `init(output:)` directly.
    convenience init(compatibleOutput output: ProcessOutput) {
        self.init { call in
            if call.arguments == ["version-info", "--json"] {
                let root = NSHomeDirectory() + "/.harflow"
                let versionInfo = "{" +
                    "\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                    "\"product_version\":\"0.0.1\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                    "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                    "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                    "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\",\"messaging.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
                return .success(stdout(versionInfo))
            }
            return .success(output)
        }
    }

    func run(
        executable: String, arguments: [String], environment: [String: String], currentDirectory _: String?, timeout _: Double
    ) async -> Result<ProcessOutput, ToolError> {
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        record(call)
        // Off the cooperative pool, exactly like `ProcessRunner`: a test that gates `answer` with a
        // blocking `AsyncGate` must not hold a pool thread, or a narrow pool (a 3-core CI runner)
        // deadlocks the whole parallel test run.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.answer(call)) }
        }
    }

    private func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }
}

func stdout(_ text: String) -> ProcessOutput {
    ProcessOutput(exitCode: 0, stdout: Data(text.utf8), stderr: "", timedOut: false)
}

/// Explicit positive-operation runner for clients that now probe the managed runtime first.
/// Negative compatibility tests should keep using `StubProcessRunner` directly.
func compatibleRunner(
    answer: @escaping @Sendable (StubProcessRunner.Call) -> Result<ProcessOutput, ToolError>
) -> StubProcessRunner {
    StubProcessRunner { call in
        if call.arguments == ["version-info", "--json"] {
            let root = NSHomeDirectory() + "/.harflow"
            let versionInfo = "{" +
                "\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                "\"product_version\":\"0.0.1\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\",\"messaging.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
            return .success(stdout(versionInfo))
        }
        return answer(call)
    }
}

/// A tiny lock-protected box, since Swift Testing runs tests concurrently and a plain `var` captured
/// across closures is not safe to mutate directly.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { self._value = value }
    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&_value)
    }
}

/// A synchronous gate a background thread can block on until the test opens it — used to force two
/// `refresh()` calls to overlap deterministically without a fixed sleep guessing at the timing.
final class AsyncGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func waitSync() { semaphore.wait() }
    func open() { semaphore.signal() }
}
