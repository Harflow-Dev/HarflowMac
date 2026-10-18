import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import Testing

@Suite struct ModelCatalogRepositoryImplTests {

    // MARK: - Fixtures

    /// Records every run's full argument set, unlike the shared `StubProcessRunner`.
    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        struct Call: Equatable {
            let executable: String
            let arguments: [String]
            let environment: [String: String]
            let currentDirectory: String?
            let timeout: Double
        }

        private let box = LockedBox<[Call]>([])
        let answer: Result<ProcessOutput, ToolError>
        var calls: [Call] { box.value }

        init(answer: Result<ProcessOutput, ToolError>) { self.answer = answer }

        func run(
            executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double
        ) async -> Result<ProcessOutput, ToolError> {
            let call = Call(
                executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout
            )
            box.mutate { $0.append(call) }
            return answer
        }
    }

    private func makeSUT(
        environment: [String: String] = ["PATH": "/login/bin"],
        runner: RecordingRunner = RecordingRunner(answer: .success(stdout(""))),
        files: [String: String] = [:]
    ) -> (sut: ModelCatalogRepositoryImpl, runner: RecordingRunner, reads: LockedBox<[String]>) {
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn("/home/me")
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(environment)
        let reads = LockedBox<[String]>([])
        let sut = ModelCatalogRepositoryImpl(toolEnvironment: toolEnvironment, runner: runner) { path in
            reads.mutate { $0.append(path) }
            return files[path].map { Data($0.utf8) }
        }
        return (sut, runner, reads)
    }

    private func codexCache(_ models: String) -> String {
        #"{"fetched_at":"2026-09-30T00:00:00Z","etag":"x","client_version":"1","identity":{},"models":[\#(models)]}"#
    }

    // MARK: - opencode

    @Test func givenOpencodeStdoutWithBlankLinesAndWhitespace_whenAsked_thenOneOptionPerModelIdInOrder() async {
        // given
        let text = "opencode/big-pickle\n\n  opencode/mimo-v2.5  \r\n   \nopencode/big-pickle\nanthropic/claude-x\n"
        let runner = RecordingRunner(answer: .success(stdout(text)))
        let (sut, _, _) = makeSUT(runner: runner)

        // when
        let models = await sut.models(for: "opencode")

        // then
        #expect(models == [
            ModelOption(value: "opencode/big-pickle", label: "opencode/big-pickle"),
            ModelOption(value: "opencode/mimo-v2.5", label: "opencode/mimo-v2.5"),
            ModelOption(value: "anthropic/claude-x", label: "anthropic/claude-x")
        ])
    }

    @Test func givenOpencode_whenAsked_thenItRunsWithTheDiscoveredEnvironmentFromHomeWithATimeout() async {
        // given
        let (sut, runner, _) = makeSUT(environment: ["PATH": "/login/bin:/interactive/bin"])

        // when
        _ = await sut.models(for: "opencode")

        // then
        #expect(runner.calls == [
            .init(
                executable: "/usr/bin/env", arguments: ["opencode", "models"],
                environment: ["PATH": "/login/bin:/interactive/bin"], currentDirectory: "/home/me", timeout: 8
            )
        ])
    }

    @Test func givenOpencodeExitsNonZero_whenAsked_thenTheListIsEmpty() async {
        // given
        let runner = RecordingRunner(answer: .success(ProcessOutput(exitCode: 1, stdout: Data("a/b\n".utf8), stderr: "boom")))
        let (sut, _, _) = makeSUT(runner: runner)

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test func givenOpencodeTimesOut_whenAsked_thenTheListIsEmpty() async {
        // given
        let runner = RecordingRunner(answer: .success(ProcessOutput(exitCode: 0, stdout: Data("a/b\n".utf8), stderr: "", timedOut: true)))
        let (sut, _, _) = makeSUT(runner: runner)

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test func givenOpencodeCannotLaunch_whenAsked_thenTheListIsEmpty() async {
        // given
        let runner = RecordingRunner(answer: .failure(.launchFailed(tool: "env", detail: "nope")))
        let (sut, _, _) = makeSUT(runner: runner)

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test func givenAnEmptyOpencodeAnswer_whenAskedTwice_thenItIsNotCachedAndRetries() async {
        // given
        let (sut, runner, _) = makeSUT()

        // when
        _ = await sut.models(for: "opencode")
        _ = await sut.models(for: "opencode")

        // then
        #expect(runner.calls.count == 2)
    }

    @Test func givenASuccessfulOpencodeAnswer_whenAskedTwice_thenTheSecondComesFromTheCache() async {
        // given
        let runner = RecordingRunner(answer: .success(stdout("a/b\n")))
        let (sut, _, _) = makeSUT(runner: runner)

        // when
        let first = await sut.models(for: "opencode")
        let second = await sut.models(for: "opencode")

        // then
        #expect(first == second)
        #expect(runner.calls.count == 1)
    }

    // MARK: - antigravity

    @Test func givenAgyStdoutWithTheFetchingNoticeAndBlanks_whenAsked_thenOneOptionPerModelLine() async {
        // given — measured shape: a `Fetching available models...` notice, then `<id>\t<label>`.
        let text = "Fetching available models...\n\ngemini-3.8-flash\tGemini 3.8 Flash\n\r\nclaude-sonnet-4-6\tClaude Sonnet 4.6\n\n"
        let runner = RecordingRunner(answer: .success(stdout(text)))
        let (sut, _, _) = makeSUT(runner: runner)

        // when
        let models = await sut.models(for: "antigravity")

        // then
        #expect(models == [
            ModelOption(value: "gemini-3.8-flash", label: "Gemini 3.8 Flash"),
            ModelOption(value: "claude-sonnet-4-6", label: "Claude Sonnet 4.6")
        ])
    }

    @Test func givenAnAgyLineWithNoTab_whenAsked_thenTheIdIsItsOwnLabel() async {
        // given
        let runner = RecordingRunner(answer: .success(stdout("gemini-3.8-flash\n")))
        let (sut, _, _) = makeSUT(runner: runner)

        // when
        let models = await sut.models(for: "antigravity")

        // then
        #expect(models == [ModelOption(value: "gemini-3.8-flash", label: "gemini-3.8-flash")])
    }

    @Test func givenAgy_whenAsked_thenItRunsWithTheDiscoveredEnvironmentFromHomeWithATimeout() async {
        // given
        let (sut, runner, _) = makeSUT(environment: ["PATH": "/login/bin:/interactive/bin"])

        // when
        _ = await sut.models(for: "antigravity")

        // then
        #expect(runner.calls == [
            .init(
                executable: "/usr/bin/env", arguments: ["agy", "models"],
                environment: ["PATH": "/login/bin:/interactive/bin"], currentDirectory: "/home/me", timeout: 8
            )
        ])
    }

    @Test(arguments: [1, 2])
    func givenAgyExitsNonZero_whenAsked_thenTheListIsEmpty(_ exitCode: Int32) async {
        // given
        let runner = RecordingRunner(answer: .success(ProcessOutput(exitCode: exitCode, stdout: Data("a/b\n".utf8), stderr: "boom")))
        let (sut, _, _) = makeSUT(runner: runner)

        // then
        #expect(await sut.models(for: "antigravity").isEmpty)
    }

    @Test func givenAgyTimesOut_whenAsked_thenTheListIsEmpty() async {
        // given
        let runner = RecordingRunner(answer: .success(ProcessOutput(exitCode: 0, stdout: Data("a/b\n".utf8), stderr: "", timedOut: true)))
        let (sut, _, _) = makeSUT(runner: runner)

        // then
        #expect(await sut.models(for: "antigravity").isEmpty)
    }

    // MARK: - codex

    @Test func givenACodexCache_whenAsked_thenOnlyListedModelsComeBackByAscendingPriority() async {
        // given
        let json = codexCache("""
        {"slug":"gpt-c","display_name":"GPT C","visibility":"list","supported_in_api":true,"priority":30},
        {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide","priority":1},
        {"slug":"gpt-a","display_name":"GPT A","visibility":"list","priority":10},
        {"slug":"gpt-b","visibility":"list","priority":20},
        {"slug":"gpt-none","display_name":"No Priority","visibility":"list"}
        """)
        let (sut, _, reads) = makeSUT(files: ["/home/me/.codex/models_cache.json": json])

        // when
        let models = await sut.models(for: "codex")

        // then
        #expect(models == [
            ModelOption(value: "gpt-a", label: "GPT A"),
            ModelOption(value: "gpt-b", label: "gpt-b"),
            ModelOption(value: "gpt-c", label: "GPT C"),
            ModelOption(value: "gpt-none", label: "No Priority")
        ])
        #expect(reads.value == ["/home/me/.codex/models_cache.json"])
    }

    @Test func givenCodexHomeIsSet_whenAsked_thenThatCacheIsRead() async {
        // given
        let json = codexCache(#"{"slug":"gpt-a","display_name":"GPT A","visibility":"list","priority":1}"#)
        let (sut, _, reads) = makeSUT(environment: ["CODEX_HOME": "/custom/codex"], files: ["/custom/codex/models_cache.json": json])

        // when
        let models = await sut.models(for: "codex")

        // then
        #expect(models.map(\.value) == ["gpt-a"])
        #expect(reads.value == ["/custom/codex/models_cache.json"])
    }

    @Test func givenNoCodexCacheFile_whenAsked_thenTheListIsEmpty() async {
        // given
        let (sut, _, _) = makeSUT()

        // then
        #expect(await sut.models(for: "codex").isEmpty)
    }

    @Test(arguments: ["", "not json", "[]", #"{"models":"nope"}"#, #"{"models":[1,"x",null]}"#, #"{"other":[]}"#])
    func givenAMalformedCodexCache_whenAsked_thenTheListIsEmpty(_ contents: String) async {
        // given
        let (sut, _, _) = makeSUT(files: ["/home/me/.codex/models_cache.json": contents])

        // then
        #expect(await sut.models(for: "codex").isEmpty)
    }

    @Test func givenACodexCacheWithOneBrokenEntry_whenAsked_thenTheGoodEntriesSurvive() async {
        // given
        let json = codexCache(#"{"slug":7,"visibility":"list"},{"visibility":"list"},{"slug":"ok","visibility":"list","priority":1}"#)
        let (sut, _, _) = makeSUT(files: ["/home/me/.codex/models_cache.json": json])

        // then
        #expect(await sut.models(for: "codex").map(\.value) == ["ok"])
    }

    // MARK: - claude, vibe, unknown

    @Test func givenClaude_whenAsked_thenTheThreeDocumentedAliasesComeBackCapitalised() async {
        // given
        let (sut, runner, _) = makeSUT()

        // when
        let models = await sut.models(for: "claude")

        // then
        #expect(models == [
            ModelOption(value: "fable", label: "Fable"),
            ModelOption(value: "opus", label: "Opus"),
            ModelOption(value: "sonnet", label: "Sonnet")
        ])
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: ["vibe", "mystery", ""])
    func givenVibeOrAnUnknownBackend_whenAsked_thenTheListIsEmptyAndNothingRuns(_ backend: String) async {
        // given
        let (sut, runner, reads) = makeSUT()

        // then
        #expect(await sut.models(for: backend).isEmpty)
        #expect(runner.calls.isEmpty)
        #expect(reads.value.isEmpty)
    }
}
