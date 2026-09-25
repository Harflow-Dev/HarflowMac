import Foundation
import MonitorCore
@testable import PbRepository
@testable import PbTerminal

/// A `ProcessRunning` stub, mirroring `PbRepositoryTests/TestSupport.swift`'s `StubProcessRunner`:
/// records every call and answers from a fixed or per-call closure — no real process spawned. Used
/// for the Terminal.app hand-off, which must never actually open Terminal.app in a test.
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
        return answer(call)
    }

    private func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }
}

func stdout(_ text: String) -> ProcessOutput {
    ProcessOutput(exitCode: 0, stdout: Data(text.utf8), stderr: "", timedOut: false)
}

/// A tiny append-only recorder for asserting call *order* across several mocks — mirrors the pattern
/// `TaskActionRepositoryImplTests`/`TaskListRepositoryImplTests` use for the same purpose.
final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _order: [String] = []
    var order: [String] {
        lock.lock(); defer { lock.unlock() }
        return _order
    }

    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        _order.append(name)
    }
}

/// `TerminalCommand`'s memberwise initializer is `internal` to `MonitorCore` (Swift never widens a
/// synthesized memberwise init past `internal`, whatever the type's own access level), and this
/// phase's scope lock forbids touching `MonitorCore`. So every command here goes through the public
/// `TakeoverWrapper.command` builder instead, same as production code does.
///
/// `/bin/cat` with no arguments blocks forever reading stdin, so the child stays alive for as long as
/// a test needs it, and is killed by `TerminalSession.terminate()` in the test's own cleanup.
func blockingCommand() throws -> TerminalCommand {
    try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
}

/// A command that exits almost immediately, for "the leader already exited" tests.
func fastExitingCommand() throws -> TerminalCommand {
    try TakeoverWrapper.command(argv: ["/bin/echo", "hi"], cwd: "/tmp", environment: [:])
}

/// A tiny append-only recorder for values seen from an async context, without the "unavailable from
/// asynchronous contexts" warning a raw `NSLock` triggers when locked directly inside `async` test
/// bodies.
final class ValueRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Value] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
