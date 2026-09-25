import Foundation
import XCTest
@testable import MonitorCore

/// A temp directory per test, removed afterwards.
func makeTempDir(_ name: String = "pbm") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fake executable: a `/bin/sh` script. Tests use these in place of polybridge-ctl and
/// polybridge-setup so nothing real is ever run.
@discardableResult
func writeFakeTool(_ dir: URL, name: String, body: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// Records every call and answers from a closure — for asserting the argv the app builds.
final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    let answer: @Sendable (Call) -> ProcessOutput

    init(answer: @escaping @Sendable (Call) -> ProcessOutput) {
        self.answer = answer
    }

    var calls: [Call] {
        lock.withLock { _calls }
    }

    func run(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        lock.withLock { _calls.append(call) }
        return .success(answer(call))
    }
}

func json(_ text: String) -> Data { Data(text.utf8) }
