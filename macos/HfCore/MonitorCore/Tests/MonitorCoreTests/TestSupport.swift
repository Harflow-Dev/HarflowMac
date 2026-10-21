import Foundation
@testable import MonitorCore

func task(
    _ id: String, status: String = "completed", spawnedBy: String? = nil, parentTaskID: String? = nil, rootTaskID: String? = nil,
    depth: Int? = nil, group: String? = nil, backend: String = "claude", minute: Int = 0
) -> TaskInfo {
    var object: [String: JSONValue] = [
        "task_id": .string(id), "status": .string(status), "backend": .string(backend),
        "depth": .number(Double(depth ?? (spawnedBy == nil ? 0 : 1))),
        "started_at": .string(String(format: "2026-09-25T10:%02d:00+00:00", minute))
    ]
    if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
    if let group { object["group"] = .string(group) }
    if let parentTaskID { object["parent_task_id"] = .string(parentTaskID) }
    if let rootTaskID { object["root_task_id"] = .string(rootTaskID) }
    return TaskInfo(.object(object))!
}

/// A temp directory per test, removed afterwards.
func makeTempDir(_ name: String = "hfm") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fake executable: a `/bin/sh` script. Tests use these in place of harflow-ctl and
/// harflow-setup so nothing real is ever run.
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

    /// Operation calls, excluding the explicit compatibility probe used by positive client tests.
    /// Gate-specific tests use `allCalls` to assert the probe and launch ordering.
    var calls: [Call] {
        lock.withLock { _calls.filter { $0.arguments != ["version-info", "--json"] } }
    }

    var allCalls: [Call] {
        lock.withLock { _calls }
    }

    func run(
        executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double
    ) async -> Result<ProcessOutput, ToolError> {
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        lock.withLock { _calls.append(call) }
        return .success(answer(call))
    }
}

/// Explicitly supplies a compatible v1 runtime handshake before answering the operation closure.
/// This keeps older business tests focused on their operation while leaving raw negative fixtures
/// independent of any implicit decoder stamping.
func compatibleRunner(answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
    RecordingRunner { call in
        if call.arguments == ["version-info", "--json"] {
            let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
            let document = "{" +
                "\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
            return ProcessOutput(exitCode: 0, stdout: json(document), stderr: "")
        }
        return answer(call)
    }
}

func json(_ text: String) -> Data { Data(text.utf8) }

/// Adds the explicit v1 envelope to a command fixture while preserving the payload's
/// discriminator fields. Tests that exercise malformed or legacy envelopes pass `json` directly.
func currentEnvelope(_ text: String, format: String, productVersion: String = HarflowVersion.current) -> Data {
    guard let object = JSONValue.parse(Data(text.utf8))?.objectValue else { return Data(text.utf8) }
    var stamped = object
    if stamped["product"] == nil { stamped["product"] = .string("harflow") }
    if stamped["format"] == nil { stamped["format"] = .string(format) }
    if let version = stamped["v"]?.wireIntegerValue, (1 ... 14).contains(version) {
        stamped["v"] = .number(1)
    } else if stamped["v"] == nil {
        stamped["v"] = .number(1)
    }
    if stamped["product_version"] == nil { stamped["product_version"] = .string(productVersion) }
    return Data(JSONValue.object(stamped).rendered().utf8)
}

func ctlJSON(_ text: String, productVersion: String = HarflowVersion.current) -> Data {
    currentEnvelope(text, format: "harflow.ctl", productVersion: productVersion)
}

func setupJSON(_ text: String, productVersion: String = HarflowVersion.current) -> Data {
    currentEnvelope(text, format: "harflow.setup", productVersion: productVersion)
}

func eventFixture(_ text: String, productVersion: String = HarflowVersion.current) -> String {
    String(data: currentEnvelope(text, format: "harflow.event", productVersion: productVersion), encoding: .utf8) ?? text
}

/// Polls `condition` every 50 ms until it becomes true or `timeout` elapses, instead of a fixed
/// sleep. Returns whether the condition was ever observed true, rather than just waiting.
@MainActor
func waitUntil(timeout: TimeInterval = 5, condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
