import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowClientTests

struct WorkflowClientTests {
    @Test(arguments: ["validate", "save"], [Int32(0), Int32(1)])
    func givenDefinition_whenTransported_thenPrivateAndRemoved(command: String, exitCode: Int32) async throws {
        // given
        let definition = JSONValue.object(["prompt": .string("Private assignment\nwith exact whitespace  ")])
        let expected = Data(definition.rendered().utf8)
        let runner = RecordingRunner { call in
            let argument = call.arguments.first { $0.hasPrefix("--definition=") }!
            let file = URL(fileURLWithPath: String(argument.dropFirst("--definition=".count)))
            let manager = FileManager.default
            #expect((try? Data(contentsOf: file)) == expected)
            let fileMode = (try? manager.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber
            let directoryMode = (try? manager.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions]) as? NSNumber
            #expect(fileMode?.intValue == 0o600)
            #expect(directoryMode?.intValue == 0o700)
            #expect(!call.arguments.contains { $0.contains("Private assignment") })
            return ProcessOutput(exitCode: exitCode, stdout: json(#"{"v":1,"ok":true,"result":{}}"#), stderr: "", timedOut: false)
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)

        // when
        if command == "validate" {
            _ = await client.validateWorkflow(definition: definition)
        } else {
            _ = await client.saveWorkflow(name: "private", definition: definition, expectedRevision: 2)
        }

        // then
        let call = try #require(runner.calls.first)
        #expect(call.arguments.first == "workflow-\(command)")
        let argument = try #require(call.arguments.first { $0.hasPrefix("--definition=") })
        let file = URL(fileURLWithPath: String(argument.dropFirst("--definition=".count)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
}
