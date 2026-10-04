import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

// MARK: - WorkflowBuildTransportTests

@Suite struct WorkflowBuildTransportTests {
    @Test(arguments: [false, true])
    func givenLargeCanvasAndBaseline_whenBuilding_thenCompleteInputsUsePrivateFilesAndCleanUp(_ failure: Bool) async throws {
        // given
        let definition = JSONValue.object(["instructions": .string(String(repeating: "canvas", count: 100_000))]).rendered()
        let source = JSONValue.object(["saved_definition": .object(["instructions": .string(String(repeating: "baseline", count: 100_000))])]).rendered()
        let paths = LockedBox<[String]>([])
        let runner = StubProcessRunner { call in
            #expect(call.arguments.reduce(0) { $0 + $1.utf8.count } < 8192)
            let input = call.arguments.first { $0.hasPrefix("--definition=") }.map { String($0.dropFirst("--definition=".count)) }
            let baseline = call.arguments.first { $0.hasPrefix("--source-file=") }.map { String($0.dropFirst("--source-file=".count)) }
            if let input, let baseline {
                paths.mutate { $0 = [input, baseline] }
                #expect((try? String(contentsOfFile: input, encoding: .utf8)) == definition)
                #expect((try? String(contentsOfFile: baseline, encoding: .utf8)) == source)
                for path in [input, baseline] {
                    #expect((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
                }
                let folder = URL(fileURLWithPath: input).deletingLastPathComponent().path
                #expect((try? FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int) == 0o700)
            } else {
                Issue.record("Build inputs were placed in argv rather than disposable files")
            }
            return failure ? .failure(.unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "failed"))
                : .success(stdout(#"{"v":4,"result":{"workflow_run_id":"builder"}}"#))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)))
        let sut = WorkflowRepositoryImpl(toolEnvironment: environment)
        // when
        let result = try? await sut.command("build", options: ["--definition-json=\(definition)", "--source=\(source)"], positionals: ["canvas"])
        // then
        #expect((result != nil) == !failure)
        #expect(paths.value.count == 2)
        for path in paths.value { #expect(!FileManager.default.fileExists(atPath: path)) }
        if let path = paths.value.first { #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)) }
    }
}

extension WorkflowBuildTransportTests {
    @Test func givenPendingBuilderProcess_whenCallerCancels_thenInputsLiveUntilProcessReturnsAndAreRemoved() async throws {
        // given
        let paths = LockedBox<[String]>([])
        let gate = AsyncGate()
        defer { gate.open() }
        let runner = StubProcessRunner { call in
            let filenames = call.arguments
.filter { option in ["--definition=", "--source-file=", "--prompt-file="].contains { option.hasPrefix($0) } }
                .map { String($0.split(separator: "=", maxSplits: 1)[1]) }
            paths.mutate { $0 = filenames }
            gate.waitSync()
            return .success(stdout(#"{"v":4,"result":{"workflow_run_id":"builder"}}"#))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)))
        let sut = WorkflowRepositoryImpl(toolEnvironment: environment)
        let task = Task {
            try await sut.command("build", options: ["--definition-json={}", "--source={}",
                                                    "--prompt=\(String(repeating: "request", count: 100_000))"], positionals: ["canvas"])
        }
        await waitUntil { paths.value.count == 3 }
        try #require(paths.value.count == 3)
        // when
        task.cancel()
        for path in paths.value { #expect(FileManager.default.fileExists(atPath: path)) }
        gate.open()
        _ = try? await task.value
        // then
        for path in paths.value { #expect(!FileManager.default.fileExists(atPath: path)) }
    }

    @Test func givenSecondInputWriteFails_whenPreparing_thenPartialDirectoryIsRemoved() throws {
        // given
        var directory: URL?
        // when
        #expect(throws: CocoaError.self) {
            _ = try WorkflowCommandInputs(options: ["--definition-json={}", "--source={}"], root: FileManager.default.temporaryDirectory) { data, url in
                directory = url.deletingLastPathComponent()
                if url.lastPathComponent == "source.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url)
            }
        }
        // then
        #expect(!FileManager.default.fileExists(atPath: try #require(directory).path))
    }

    @Test func givenUnrelatedPromptAndExternalInput_whenPreparing_thenTheyRemainUnchanged() throws {
        // given
        let options = ["--prompt=Explain --source={}", "--definition=/external/canvas.json", "--backend=codex"]
        // when
        let input = try WorkflowCommandInputs.prepare(options: options)
        defer { input.cleanUp() }
        // then
        let option = try #require(input.options.first { $0.hasPrefix("--prompt-file=") })
        let path = String(option.dropFirst("--prompt-file=".count))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "Explain --source={}")
        #expect(input.options.contains("--definition=/external/canvas.json"))
        #expect(!input.options.contains { $0.hasPrefix("--source-file=") })
    }
}

extension WorkflowBuildTransportTests {
    @Test(arguments: ["build", "start", "builder-followup"], [false, true])
    func givenLargeWorkflowPrompt_whenDispatching_thenCompletePromptUsesDisposableFile(_ command: String, _ failure: Bool) async throws {
        // given
        let prompt = String(repeating: "Detailed request 🦋\r\n", count: 30_000)
        let paths = LockedBox<[String]>([])
        let runner = StubProcessRunner { call in
            #expect(call.arguments.reduce(0) { $0 + $1.utf8.count } < 8192)
            if let option = call.arguments.first(where: { $0.hasPrefix("--prompt-file=") }) {
                let path = String(option.dropFirst("--prompt-file=".count))
                paths.mutate { $0 = [path] }
                #expect((try? String(contentsOfFile: path, encoding: .utf8)) == prompt)
                #expect((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
            } else {
                Issue.record("Workflow prompt was placed in argv")
            }
            return failure ? .failure(.unreadable(tool: "polybridge-ctl", exitCode: 1, stderr: "failed"))
                : .success(stdout(#"{"v":4,"result":{"workflow_run_id":"builder"}}"#))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)))
        let sut = WorkflowRepositoryImpl(toolEnvironment: environment)
        // when
        let result = try? await sut.command(command, options: ["--prompt=\(prompt)"], positionals: ["canvas"])
        // then
        #expect((result != nil) == !failure)
        #expect(paths.value.count == 1)
        for path in paths.value { #expect(!FileManager.default.fileExists(atPath: path)) }
    }
}
