import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowClient private input files

extension WorkflowClientTests {
    @Test(arguments: ["validate", "save"])
    func givenExplicitTemporaryRoot_whenTransporting_thenInputStaysInsideSelectedRootAndIsRemoved(command: String) async throws {
        // given
        let base = try privateInputRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let expected = JSONValue.object(["instructions": .string("Exact private\nbytes  ")])
        let runner = compatibleRunner { call in
            let argument = call.arguments.first { $0.hasPrefix("--definition=") }!
            let file = URL(fileURLWithPath: String(argument.dropFirst("--definition=".count)))
            #expect(file.deletingLastPathComponent().deletingLastPathComponent() == base)
            #expect((try? Data(contentsOf: file)) == Data(expected.rendered().utf8))
            #expect(call.environment["TMPDIR"] == base.path)
            return ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":1,"ok":true,"result":{}}"#), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: ["TMPDIR": base.path], runner: runner)
        // when
        let result = if command == "validate" {
            await client.validateWorkflow(definition: expected)
        } else {
            await client.saveWorkflow(name: "Private", definition: expected, expectedRevision: 4)
        }
        // then
        _ = try result.get()
        #expect(runner.calls.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test(arguments: ["blank", "whitespace", "relative", "nul", "missing", "file", "unwritable"], ["validate", "save"])
    func givenInvalidExplicitTemporaryRoot_whenTransporting_thenRefusesWithoutDispatchOrFallback(kind: String, command: String) async throws {
        // given
        let base = try privateInputRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            try? FileManager.default.removeItem(at: base)
        }
        let root: String
        switch kind {
        case "blank": root = ""
        case "whitespace": root = " \n "
        case "relative": root = "relative/path"
        case "nul": root = base.path + "\0suffix"
        case "missing": root = base.appendingPathComponent("absent").path
        case "file":
            let file = base.appendingPathComponent("plain-file")
            try Data("foreign".utf8).write(to: file)
            root = file.path
        default:
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
            root = base.path
        }
        let runner = compatibleRunner { _ in
            Issue.record("Invalid input root dispatched a CLI operation")
            return ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":1,"ok":true,"result":{}}"#), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: ["TMPDIR": root], runner: runner)
        // when
        let result = if command == "validate" {
            await client.validateWorkflow(definition: .object([:]))
        } else {
            await client.saveWorkflow(name: "Private", definition: .object([:]), expectedRevision: 0)
        }
        // then
        if case .success = result { Issue.record("Invalid explicit root was accepted") }
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: ["directory", "file", "symlink"])
    func givenExistingInputPath_whenExclusiveCreationFails_thenForeignPathRemainsUntouched(kind: String) throws {
        // given
        let base = try privateInputRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let identifier = UUID()
        let directory = base.appendingPathComponent("harflow-workflow-" + identifier.uuidString)
        let victim = base.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        let marker = victim.appendingPathComponent("marker")
        try Data("preserve".utf8).write(to: marker)
        if kind == "directory" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } else if kind == "file" {
            try Data("foreign file".utf8).write(to: directory)
        } else {
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: victim)
        }
        // when / then
        #expect(throws: Error.self) {
            _ = try WorkflowDefinitionInput(definition: .object([:]), baseDirectory: base.path, identifier: identifier)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try Data(contentsOf: marker) == Data("preserve".utf8))
        if kind == "file" { #expect(try Data(contentsOf: directory) == Data("foreign file".utf8)) }
    }

    private func privateInputRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
