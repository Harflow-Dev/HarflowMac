import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct ModelCatalogRepositoryImplTests {

    // MARK: - Fixtures

    struct Row {
        let id: String
        let label: String
        var effort: String = "null"
        var isDefault: String = "null"
    }

    static func listingDocument(
        backend: String = "opencode", state: String = "available", reason: String? = nil, source: String = "cli_output",
        rows: [Row] = []
    ) -> String {
        let models = rows.map {
            #"{"id":"\#($0.id)","label":"\#($0.label)","default":\#($0.isDefault),"effort_levels":\#($0.effort)}"#
        }
.joined(separator: ",")
        let reasonText = reason.map { "\"\($0)\"" } ?? "null"
        return #"{"v":1,"product":"harflow","format":"harflow.ctl","product_version":"0.0.1","result":{"backend":"\#(backend)","#
            + #""state":"\#(state)","reason":\#(reasonText),"source":"\#(source)","scope":"user","advisory":true,"#
            + #""harness_version":null,"source_observed_at":null,"observed_at":"2026-11-14T00:00:00Z","truncated":false,"#
            + #""dropped_count":0,"models":[\#(models)]}}"#
    }

    private func listing(
        backend: String = "opencode", state: String = "available", reason: String? = nil, source: String = "cli_output",
        rows: [Row] = []
    ) -> String {
        Self.listingDocument(backend: backend, state: state, reason: reason, source: source, rows: rows)
    }

    private func refusal(code: String, detail: String? = nil) -> String {
        let detailText = detail.map { #","detail":"\#($0)""# } ?? ""
        return #"{"v":1,"product":"harflow","format":"harflow.ctl","product_version":"0.0.1","error":{"code":"\#(code)","#
            + #""message":"Backend model listing requires a verified direct caller.","#
            + #""data":{"coverage":"unknown","check":"direct_caller_required"\#(detailText)}}}"#
    }

    /// A ctl client whose runner answers the version-info handshake (with or without `backend-models.v1`)
    /// and then the command from `answer`.
    private func client(
        capability: Bool = true, answer: @escaping @Sendable (StubProcessRunner.Call) -> Result<ProcessOutput, ToolError>
    ) -> (client: CtlClient, runner: StubProcessRunner) {
        let runner = StubProcessRunner { call in
            guard call.arguments == ["version-info", "--json"] else { return answer(call) }
            let root = NSHomeDirectory() + "/.harflow"
            let capabilities = #""ctl.v1","setup.v1","events.v1""# + (capability ? #","backend-models.v1""# : "")
            let versionInfo = #"{"product":"harflow","format":"harflow.version-info","v":1,"product_version":"0.0.1","#
                + #""component":"engine","state_root":"\#(root)","contracts":{"ctl":{"format":"harflow.ctl","v":1},"#
                + #""setup":{"format":"harflow.setup","v":1},"events":{"format":"harflow.event","v":1}},"#
                + #""capabilities":[\#(capabilities)],"os":"darwin","architecture":"arm64"}"#
            return .success(stdout(versionInfo))
        }
        return (CtlClient(executable: "/bin/echo", environment: [:], runner: runner), runner)
    }

    private func makeSUT(
        ctl: Result<CtlClient, ToolError>
    ) -> (sut: ModelCatalogRepositoryImpl, toolEnvironment: MockToolEnvironmentRepository) {
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(ctl)
        return (ModelCatalogRepositoryImpl(toolEnvironment: toolEnvironment), toolEnvironment)
    }

    private func makeSUT(
        answering text: String
    ) -> (sut: ModelCatalogRepositoryImpl, runner: StubProcessRunner) {
        let (client, runner) = client { _ in .success(stdout(text)) }
        return (makeSUT(ctl: .success(client)).sut, runner)
    }

    private func commandCalls(_ runner: StubProcessRunner) -> [[String]] {
        runner.calls.map(\.arguments).filter { $0.first == "backend-models" }
    }

    // MARK: - Available listings

    @Test func givenAnAvailableListing_whenAsked_thenOneOptionPerRowInEngineOrderWithEffortLevels() async {
        // given
        let text = listing(rows: [
            Row(id: "opencode/big-pickle", label: "Big Pickle"),
            Row(id: "opencode/hy3-free", label: "Hy3 Free", effort: #"["low","medium","high"]"#),
            Row(id: "opencode/no-levels", label: "No Levels", effort: "[]", isDefault: "true")
        ])
        let (sut, _) = makeSUT(answering: text)

        // when
        let models = await sut.models(for: "opencode")

        // then
        #expect(models == [
            ModelOption(value: "opencode/big-pickle", label: "Big Pickle", effortLevels: nil),
            ModelOption(value: "opencode/hy3-free", label: "Hy3 Free", effortLevels: ["low", "medium", "high"]),
            ModelOption(value: "opencode/no-levels", label: "No Levels", effortLevels: [])
        ])
    }

    @Test func givenABackend_whenAsked_thenOneHandshakeAndOneBackendOptionCommandRun() async {
        // given
        let (sut, runner) = makeSUT(answering: listing(backend: "codex", rows: [Row(id: "gpt-a", label: "GPT A")]))

        // when
        _ = await sut.models(for: "codex")

        // then
        #expect(runner.calls.map(\.arguments) == [["version-info", "--json"], ["backend-models", "--backend=codex", "--json"]])
    }

    @Test func givenAvailableListingWithNoRows_whenAsked_thenTheListIsEmpty() async {
        // given
        let (sut, _) = makeSUT(answering: listing(rows: []))

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    // MARK: - Labels

    @Test func givenSharedAndEmptyLabels_whenAsked_thenThoseRowsAreTitledByIdAndUniqueLabelsStay() async {
        // given
        let text = listing(rows: [
            Row(id: "a/one", label: "Same"), Row(id: "b/two", label: "Unique"), Row(id: "c/three", label: "Same"),
            Row(id: "d/four", label: "")
        ])
        let (sut, _) = makeSUT(answering: text)

        // when
        let models = await sut.models(for: "opencode")

        // then
        #expect(models.map(\.value) == ["a/one", "b/two", "c/three", "d/four"])
        #expect(models.map(\.label) == ["a/one", "Unique", "c/three", "d/four"])
    }

    // MARK: - Not available

    @Test(arguments: [
        ("not_installed", nil as String?), ("unsupported", nil), ("unavailable", "timeout"), ("unavailable", "exit_nonzero"),
        ("unavailable", "auth_required"), ("unavailable", "unparseable"), ("unavailable", "source_missing"),
        ("unavailable", "output_ceiling"), ("unavailable", "spawn_failed"), ("unavailable", "future_reason"), ("future_state", nil)
    ])
    func givenAnyNonAvailableState_whenAsked_thenTheListIsEmptyEvenIfRowsArePresent(_ state: String, _ reason: String?) async {
        // given
        let (sut, _) = makeSUT(answering: listing(state: state, reason: reason, rows: [Row(id: "x/y", label: "X Y")]))

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test(arguments: [
        ("agent_caller", nil as String?), ("caller_undecidable", nil), ("caller_undecidable", "root_present_unmarked"),
        ("caller_undecidable", "lock_timeout"), ("future_refusal", nil)
    ])
    func givenAnEngineRefusal_whenAsked_thenTheListIsEmpty(_ code: String, _ detail: String?) async {
        // given
        let (sut, _) = makeSUT(answering: refusal(code: code, detail: detail))

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test func givenTheCapabilityIsMissing_whenAsked_thenOnlyTheHandshakeRunsAndTheListIsEmpty() async {
        // given
        let (client, runner) = client(capability: false) { _ in .success(stdout(listing(rows: [Row(id: "x/y", label: "X")]))) }
        let (sut, _) = makeSUT(ctl: .success(client))

        // when
        let models = await sut.models(for: "opencode")

        // then
        #expect(models.isEmpty)
        #expect(commandCalls(runner).isEmpty)
    }

    @Test func givenAnUnknownBackend_whenAsked_thenTheEnginesUsageErrorYieldsAnEmptyList() async {
        // given
        let usage = #"{"v":1,"product":"harflow","format":"harflow.ctl","product_version":"0.0.1","error":{"code":"usage","#
            + #""message":"argument --backend: invalid choice: 'mystery' (choose from 'claude')"}}"#
        let (sut, _) = makeSUT(answering: usage)

        // then
        #expect(await sut.models(for: "mystery").isEmpty)
    }

    @Test(arguments: ["", "not json", "[]", #"{"result":{"backend":"opencode"}}"#, #"{"result":{"models":"nope"}}"#])
    func givenAnUnreadableDocument_whenAsked_thenTheListIsEmpty(_ document: String) async {
        // given
        let (sut, _) = makeSUT(answering: document)

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test func givenTheCommandTimesOut_whenAsked_thenTheListIsEmpty() async {
        // given
        let (client, _) = client { _ in .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true)) }
        let (sut, _) = makeSUT(ctl: .success(client))

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test func givenTheCommandCannotLaunch_whenAsked_thenTheListIsEmpty() async {
        // given
        let (client, _) = client { _ in .failure(.launchFailed(tool: "harflow-ctl", detail: "nope")) }
        let (sut, _) = makeSUT(ctl: .success(client))

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test(arguments: [
        ToolError.notFound(tool: "harflow-ctl", searched: []),
        ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "runtime is preparing")
    ])
    func givenNoCtlClientBecauseTheRuntimeIsNotReady_whenAsked_thenTheListIsEmpty(_ failure: ToolError) async {
        // given
        let (sut, _) = makeSUT(ctl: .failure(failure))

        // then
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    // MARK: - Caching

    @Test func givenARuntimeThatIsNotReady_whenAskedAgainOnceItIsReady_thenTheSecondAskRetriesAndSucceeds() async {
        // given
        let (client, runner) = client { _ in .success(stdout(listing(rows: [Row(id: "a/b", label: "A B")]))) }
        let current = LockedBox<Result<CtlClient, ToolError>>(.failure(.notFound(tool: "harflow-ctl", searched: [])))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willProduce { current.value }
        let sut = ModelCatalogRepositoryImpl(toolEnvironment: toolEnvironment)

        // when
        let first = await sut.models(for: "opencode")
        current.mutate { $0 = .success(client) }
        let second = await sut.models(for: "opencode")

        // then
        #expect(first.isEmpty)
        #expect(second.map(\.value) == ["a/b"])
        #expect(commandCalls(runner).count == 1)
    }

    @Test func givenASuccessfulAnswer_whenAskedTwice_thenTheSecondComesFromTheCache() async {
        // given
        let (sut, runner) = makeSUT(answering: listing(rows: [Row(id: "a/b", label: "A B")]))

        // when
        let first = await sut.models(for: "opencode")
        let second = await sut.models(for: "opencode")

        // then
        #expect(first == second)
        #expect(commandCalls(runner).count == 1)
    }

    @Test func givenTwoBackends_whenEachIsAskedTwice_thenEachBackendIsCachedSeparately() async {
        // given
        let (sut, runner) = makeSUT(answering: listing(rows: [Row(id: "a/b", label: "A B")]))

        // when
        _ = await sut.models(for: "opencode")
        _ = await sut.models(for: "codex")
        _ = await sut.models(for: "opencode")
        _ = await sut.models(for: "codex")

        // then
        #expect(commandCalls(runner) == [["backend-models", "--backend=opencode", "--json"], ["backend-models", "--backend=codex", "--json"]])
    }

    @Test(arguments: [
        listingDocument(state: "unavailable", reason: "timeout"), listingDocument(state: "not_installed"),
        listingDocument(rows: []), #"{"result":{}}"#
    ])
    func givenAnAnswerWithNoSuggestions_whenAskedTwice_thenItIsNotCachedAndRetries(_ document: String) async {
        // given
        let (sut, runner) = makeSUT(answering: document)

        // when
        _ = await sut.models(for: "opencode")
        _ = await sut.models(for: "opencode")

        // then
        #expect(commandCalls(runner).count == 2)
    }

    @Test func givenAFailureThenASuccess_whenAskedTwice_thenTheSuccessIsReturnedAndCached() async {
        // given
        let attempts = LockedBox(0)
        let (client, runner) = client { _ in
            let attempt = attempts.value
            attempts.mutate { $0 += 1 }
            return .success(stdout(attempt == 0 ? refusal(code: "caller_undecidable", detail: "lock_timeout")
                    : listing(rows: [Row(id: "a/b", label: "A B")])))
        }
        let (sut, _) = makeSUT(ctl: .success(client))

        // when
        let first = await sut.models(for: "opencode")
        let second = await sut.models(for: "opencode")
        let third = await sut.models(for: "opencode")

        // then
        #expect(first.isEmpty)
        #expect(second.map(\.value) == ["a/b"])
        #expect(third == second)
        #expect(commandCalls(runner).count == 2)
    }

    @Test func givenConcurrentRequestsForTheSameBackend_whenAnswered_thenOneCommandServesAll() async {
        // given
        let gate = AsyncGate()
        let (client, runner) = client { _ in
            gate.waitSync()
            return .success(stdout(listing(rows: [Row(id: "a/b", label: "A B")])))
        }
        let (sut, _) = makeSUT(ctl: .success(client))

        // when
        async let first = sut.models(for: "opencode")
        async let second = sut.models(for: "opencode")
        async let third = sut.models(for: "opencode")
        await waitUntil { !commandCalls(runner).isEmpty }
        gate.open()
        let results = await [first, second, third]

        // then
        #expect(results.allSatisfy { $0.map(\.value) == ["a/b"] })
        #expect(commandCalls(runner).count == 1)
    }
}
