import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

struct WorkflowControlTransportTests {
    @Test(arguments: ["resume", "recover"], [false, true])
    func givenLargeUnicodeInstructions_whenControllingRun_thenPrivateFilePreservesAllBytesAndCleansUp(command: String, failure: Bool) async throws {
        let flag = command == "resume" ? "--instructions" : "--reason"
        let text = " \r\n--monitor 🦋 " + String(repeating: "Large answer\r\n", count: 100_000) + "\r\n "
        let paths = LockedBox<[String]>([])
        let runner = StubProcessRunner { call in
            #expect(call.arguments.reduce(0) { $0 + $1.utf8.count } < 8192)
            #expect(!call.arguments.contains { $0.hasPrefix(flag + "=") })
            #expect(call.arguments.contains("--monitor"))
            #expect(call.arguments.contains("--additional-attempts=2"))
            #expect(call.arguments.contains("--decision-id=decision") == (command == "resume"))
            if let option = call.arguments.first(where: { $0.hasPrefix(flag + "-file=") }) {
                let path = String(option.dropFirst((flag + "-file=").count))
                paths.mutate { $0 = [path] }
                #expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data(text.utf8))
                #expect((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                #expect((try? FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int) == 0o700)
            } else { Issue.record("Control payload remained in argv") }
            return failure ? .failure(.unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "failed"))
                : .success(stdout(#"{"v":5,"result":{"workflow_run_id":"run"}}"#))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)))
        let sut = WorkflowRepositoryImpl(toolEnvironment: environment)
        let options = [flag + "=" + text, "--monitor", "--additional-attempts=2"] + (command == "resume" ? ["--decision-id=decision"] : [])
        let result = try? await sut.command(command, options: options, positionals: ["run"])
        #expect((result != nil) == !failure)
        #expect(paths.value.count == 1)
        for path in paths.value {
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
        }
    }

    @Test(arguments: ["resume", "recover"])
    func givenControlProcessPending_whenCancelled_thenFileLivesUntilProcessReturns(command: String) async throws {
        let flag = command == "resume" ? "--instructions" : "--reason"
        let paths = LockedBox<[String]>([])
        let gate = AsyncGate()
        defer { gate.open() }
        let runner = StubProcessRunner { call in
            if let option = call.arguments.first(where: { $0.hasPrefix(flag + "-file=") }) {
                paths.mutate { $0 = [String(option.dropFirst((flag + "-file=").count))] }
            }
            gate.waitSync()
            return .success(stdout(#"{"v":5,"result":{"workflow_run_id":"run"}}"#))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)))
        let sut = WorkflowRepositoryImpl(toolEnvironment: environment)
        let process = Task { try await sut.command(command, options: [flag + "=" + String(repeating: "answer", count: 100_000)], positionals: ["run"]) }
        await waitUntil { paths.value.count == 1 }
        try #require(paths.value.count == 1)
        process.cancel()
        #expect(FileManager.default.fileExists(atPath: paths.value[0]))
        gate.open()
        _ = try? await process.value
        #expect(!FileManager.default.fileExists(atPath: paths.value[0]))
    }
}
