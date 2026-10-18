import Foundation
import MonitorCore
@testable import PbRepository

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
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    let answer: @Sendable (Call) -> Result<ProcessOutput, ToolError>

    init(answer: @escaping @Sendable (Call) -> Result<ProcessOutput, ToolError>) {
        self.answer = answer
    }

    convenience init(output: ProcessOutput) {
        self.init { _ in .success(output) }
    }

    func run(
        executable: String, arguments: [String], environment _: [String: String], currentDirectory _: String?, timeout _: Double
    ) async -> Result<ProcessOutput, ToolError> {
        let call = Call(executable: executable, arguments: arguments)
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
