import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskChangesClientTests

struct TaskChangesClientTests {
    private static let page = changesResult(Doc.page())

    // MARK: Capability and handshake

    @Test func givenSyntheticRuntimeWithoutTheCapability_whenListed_thenNoTaskChangesCommandLaunches() async {
        // given
        let runner = changesRunner(capability: { false }) { _ in Self.page }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: "task")
        // then
        guard case .failure(.unsupportedCommand(_, let command, let detail)) = result else { Issue.record("Missing capability must refuse"); return }
        #expect(command == "task-changes" && detail.contains("task-changes.v1"))
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"]])
    }

    @Test func givenSyntheticRuntimeWithoutTheCapability_whenTextIsRead_thenNoTaskChangesCommandLaunches() async throws {
        // given
        let runner = changesRunner(capability: { false }) { _ in Self.page }
        let client = changesClient(runner)
        // when
        let byRow = await client.taskChangesTextChunk(taskID: "task", selector: try Doc.selector())
        let byCursor = await client.taskChangesTextChunk(taskID: "task", cursor: "c")
        // then
        for result in [byRow.map { _ in () }, byCursor.map { _ in () }] {
            guard case .failure(.unsupportedCommand) = result else { Issue.record("Missing capability must refuse"); return }
        }
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.count == 2)
    }

    @Test func givenSyntheticRepeatedReads_whenCapabilityDisappears_thenEachCallHandshakesFreshAndSecondLaunchesNothing() async throws {
        // given
        let reads = TCBox(0)
        let runner = changesRunner(capability: { reads.value < 2 }) { call in
            if call.arguments.first == "task-changes" { reads.mutate { $0 += 1 } }
            return Self.page
        }
        let client = changesClient(runner)
        // when
        let first = await client.taskChangesPage(taskID: Doc.taskID)
        let second = await client.taskChangesPage(taskID: Doc.taskID)
        let third = await client.taskChangesPage(taskID: Doc.taskID)
        // then
        #expect((try? first.get()) != nil && (try? second.get()) != nil)
        guard case .failure(.unsupportedCommand) = third else { Issue.record("Missing capability must refuse"); return }
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info", "task-changes", "version-info", "task-changes", "version-info"])
    }

    @Test(arguments: ["foreign-root", "failed-probe"])
    func givenSyntheticIncompatibleRuntime_whenListed_thenNoTaskChangesCommandLaunches(mode: String) async {
        // given
        let runner = RecordingRunner { call in
            mode == "failed-probe" ? ProcessOutput(exitCode: 1, stdout: Data(), stderr: "probe failed")
                : changesProbe(["HOME": "/foreign-\(call.environment.count)"])
        }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: "task")
        // then
        guard case .failure = result else { Issue.record("Incompatible runtime accepted"); return }
        #expect(runner.calls.isEmpty)
    }

    // MARK: Argv

    @Test func givenSyntheticDefaultListing_whenRead_thenArgvCarriesTheDefaultLimitAndGuardedTaskId() async {
        // given
        let runner = changesRunner { _ in changesResult(Doc.page(task: "--help")) }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: "--help")
        // then
        #expect((try? result.get().taskID) == "--help")
        #expect(runner.calls.map(\.arguments) == [["task-changes", "--limit=200", "--json", "--", "--help"]])
    }

    @Test(arguments: [1, 500])
    func givenSyntheticLimitBoundAndCursor_whenRead_thenArgvCarriesLimitThenCursorInOptionForm(limit: Int) async {
        // given
        let cursor = "-opaque=cursor+/=="
        let runner = changesRunner { _ in changesResult(Doc.page(limit: limit)) }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: Doc.taskID, limit: limit, cursor: cursor)
        // then
        #expect((try? result.get().limit) == limit)
        #expect(runner.calls.map(\.arguments) == [["task-changes", "--limit=\(limit)", "--cursor=\(cursor)", "--json", "--", Doc.taskID]])
    }

    @Test func givenSyntheticAsciiSelector_whenTextRead_thenArgvCarriesRootScopeAndBase64PathWithoutLimitOrCursor() async throws {
        // given
        let selector = try Doc.selector(root: "-root with space", scope: .committedRange, path: "dir/a b.txt")
        let runner = changesRunner { _ in changesResult(Doc.chunk(path: "dir/a b.txt", scope: "committed_range", root: "-root with space")) }
        // when
        let result = await changesClient(runner).taskChangesTextChunk(taskID: Doc.taskID, selector: selector)
        // then
        #expect((try? result.get().path.utf8String) == "dir/a b.txt")
        #expect(runner.calls.map(\.arguments) == [[
            "task-changes", "--repository-root=-root with space", "--scope=committed_range",
            "--path-b64=\(Data("dir/a b.txt".utf8).base64EncodedString())", "--json", "--", Doc.taskID
        ]])
    }

    @Test func givenSyntheticNonUtf8PathBytes_whenTextRead_thenArgvCarriesTheExactBytesAsStandardBase64() async throws {
        // given
        let bytes = Data([0xFB, 0xFF, 0xBF, 0x00, 0xFE])
        let selector = try #require(TaskChangesSelector(repositoryRoot: Doc.root, scope: .workingTree, pathBytes: bytes))
        let runner = changesRunner { _ in changesResult(Doc.chunk(path: nil, pathB64: bytes.base64EncodedString())) }
        // when
        let result = await changesClient(runner).taskChangesTextChunk(taskID: Doc.taskID, selector: selector)
        // then
        let encoded = bytes.base64EncodedString()
        #expect(encoded.contains("+") || encoded.contains("/"), "standard alphabet, not URL-safe")
        #expect((try? result.get().path.bytes) == bytes)
        #expect(runner.calls.first?.arguments.contains("--path-b64=\(encoded)") == true)
        let carried = runner.calls.first?.arguments.first { $0.hasPrefix("--path-b64=") }?.dropFirst("--path-b64=".count)
        #expect(carried.map { !$0.contains("-") && !$0.contains("_") } == true)
    }

    @Test func givenSyntheticTextCursor_whenRead_thenArgvIsTheCursorAloneWithNoSelectorsOrLimit() async {
        // given
        let runner = changesRunner { _ in changesResult(Doc.chunk()) }
        // when
        let result = await changesClient(runner).taskChangesTextChunk(taskID: Doc.taskID, cursor: "next")
        // then
        #expect((try? result.get().taskID) == Doc.taskID)
        #expect(runner.calls.map(\.arguments) == [["task-changes", "--cursor=next", "--json", "--", Doc.taskID]])
    }

    // MARK: Request validation

    @Test(arguments: [0, 501, -3])
    func givenSyntheticLimitOutsideTheContract_whenListed_thenNoProcessLaunches(limit: Int) async {
        // given
        let runner = changesRunner { _ in Self.page }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: "task", limit: limit)
        // then
        guard case .failure = result else { Issue.record("Invalid limit accepted"); return }
        #expect(runner.allCalls.isEmpty)
    }

    @Test(arguments: ["", "nul\0byte", String(repeating: "c", count: 2049)])
    func givenSyntheticInvalidCursor_whenReadAsListingOrText_thenNoProcessLaunches(cursor: String) async {
        // given
        let runner = changesRunner { _ in Self.page }
        let client = changesClient(runner)
        // when
        let listing = await client.taskChangesPage(taskID: "task", cursor: cursor)
        let text = await client.taskChangesTextChunk(taskID: "task", cursor: cursor)
        // then
        guard case .failure = listing, case .failure = text else { Issue.record("Invalid cursor accepted"); return }
        #expect(runner.allCalls.isEmpty)
    }

    @Test(arguments: ["", "has\0nul", String(repeating: "t", count: 1025)])
    func givenSyntheticInvalidTaskId_whenRead_thenNoProcessLaunches(taskID: String) async throws {
        // given
        let runner = changesRunner { _ in Self.page }
        let client = changesClient(runner)
        // when
        let listing = await client.taskChangesPage(taskID: taskID)
        let byRow = await client.taskChangesTextChunk(taskID: taskID, selector: try Doc.selector())
        let byCursor = await client.taskChangesTextChunk(taskID: taskID, cursor: "c")
        // then
        guard case .failure = listing, case .failure = byRow, case .failure = byCursor else { Issue.record("Invalid task id accepted"); return }
        #expect(runner.allCalls.isEmpty)
    }

    // MARK: Identity

    @Test(arguments: ["exact", "prefix", "wrong-input", "wrong-resolution", "no-resolution", "short-prefix", "other-task"])
    func givenSyntheticResponseIdentity_whenListed_thenOnlyExactOrProvenPrefixIsAccepted(mode: String) async {
        // given
        let full = "abcdefgh-full-task"
        let requested = mode == "exact" ? "tiny" : mode == "short-prefix" ? "abc" : "abcdefgh"
        var page = Doc.page(task: mode == "exact" ? "tiny" : mode == "other-task" ? "zzz" : full)
        if mode != "exact", mode != "no-resolution", mode != "other-task" {
            page = page.setting(["resolved_from"], to: .object([
                "input": .string(mode == "wrong-input" ? "other" : requested), "task_id": .string(mode == "wrong-resolution" ? "other" : full)
            ]))
        }
        let runner = changesRunner { _ in changesResult(page) }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: requested)
        // then
        if mode == "exact" || mode == "prefix" {
            #expect((try? result.get()) != nil)
        } else {
            guard case .failure = result else { Issue.record("Foreign identity accepted"); return }
        }
    }

    @Test func givenSyntheticTextForAnotherTask_whenRead_thenItIsRefused() async {
        // given
        let runner = changesRunner { _ in changesResult(Doc.chunk(task: "other")) }
        // when
        let result = await changesClient(runner).taskChangesTextChunk(taskID: Doc.taskID, cursor: "c")
        // then
        guard case .failure = result else { Issue.record("Foreign task accepted"); return }
    }

    // MARK: Documents

    @Test func givenSyntheticStdoutAtAndOverTheDocumentBound_whenListed_thenOnlyTheBoundIsAccepted() async throws {
        // given
        func padded(to size: Int) throws -> ProcessOutput {
            var padding = 0
            var data = Data()
            for _ in 0 ..< 3 {
                let page = Doc.page().setting(["observed_at"], to: .string("2026-10-14T17:46:40+00:00" + String(repeating: "x", count: padding)))
                data = ctlJSON(JSONValue.object(["result": page]).rendered())
                padding += size - data.count
            }
            #expect(data.count == size)
            return ProcessOutput(exitCode: 0, stdout: data, stderr: "")
        }
        let exact = try padded(to: TaskChangesLimits.maxDocumentBytes)
        let over = try padded(to: TaskChangesLimits.maxDocumentBytes + 1)
        // when
        let accepted = await changesClient(changesRunner { _ in exact }).taskChangesPage(taskID: Doc.taskID)
        let refused = await changesClient(changesRunner { _ in over }).taskChangesPage(taskID: Doc.taskID)
        // then
        #expect((try? accepted.get()) != nil)
        guard case .failure(.unreadable(_, _, let stderr)) = refused else { Issue.record("Oversized document accepted"); return }
        #expect(stderr.contains("byte limit"))
    }

    @Test(arguments: [0, 1])
    func givenSyntheticOversizedNonJsonStdout_whenListed_thenTheSizeFailureIsReportedWithoutParsing(exit: Int32) async {
        // given: parsing would report an unreadable document without the size message
        let noise = ProcessOutput(exitCode: exit, stdout: Data(repeating: 0x78, count: TaskChangesLimits.maxDocumentBytes + 1), stderr: "")
        let runner = changesRunner { _ in noise }
        // when
        let listing = await changesClient(runner).taskChangesPage(taskID: Doc.taskID)
        let text = await changesClient(runner).taskChangesTextChunk(taskID: Doc.taskID, cursor: "c")
        // then
        for result in [listing.map { _ in () }, text.map { _ in () }] {
            guard case .failure(.unreadable(_, let code, let stderr)) = result else { Issue.record("Oversized output accepted"); return }
            #expect(stderr == "task-changes exceeded document byte limit" && code == exit)
        }
    }

    @Test func givenSyntheticNonJsonStdoutWithinTheBound_whenListed_thenItIsAnOrdinaryUnreadableFailure() async {
        // given
        let runner = changesRunner { _ in ProcessOutput(exitCode: 0, stdout: Data("not json".utf8), stderr: "") }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: Doc.taskID)
        // then
        guard case .failure(.unreadable(_, _, let stderr)) = result else { Issue.record("Garbage accepted"); return }
        #expect(!stderr.contains("byte limit"))
    }

    @Test func givenSyntheticResultDocumentWithNonZeroExit_whenListed_thenItIsRefused() async {
        // given
        let runner = changesRunner { _ in changesResult(Doc.page(), exit: 1) }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: Doc.taskID)
        // then
        guard case .failure = result else { Issue.record("Result under a failing exit accepted"); return }
    }

    @Test func givenSyntheticDocumentWithoutAResult_whenListed_thenItIsRefused() async {
        // given
        let runner = changesRunner { _ in ProcessOutput(exitCode: 0, stdout: ctlJSON("{\"other\":{}}"), stderr: "") }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: Doc.taskID)
        // then
        guard case .failure = result else { Issue.record("Document without result accepted"); return }
    }

    @Test func givenSyntheticMalformedListing_whenRead_thenItIsRefusedAsUnreadable() async {
        // given
        let runner = changesRunner { _ in changesResult(Doc.page().setting(["limit"], to: .number(7))) }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: Doc.taskID)
        // then
        guard case .failure(.unreadable) = result else { Issue.record("Mismatched limit accepted"); return }
    }

    @Test func givenVendoredListingFixture_whenReadAtADifferentLimit_thenTheEchoedLimitMismatchIsRefused() async throws {
        // given
        let output = TCFixture.output("available-listing", exit: 0)
        let runner = changesRunner { _ in output }
        let client = changesClient(runner)
        // when
        let matching = await client.taskChangesPage(taskID: "task-changes-available", limit: 2)
        let mismatched = await client.taskChangesPage(taskID: "task-changes-available", limit: 200)
        // then
        #expect((try? matching.get().limit) == 2)
        guard case .failure = mismatched else { Issue.record("Echoed limit mismatch accepted"); return }
    }

    // MARK: Refusals

    @Test(arguments: [
        "changes_cursor_expired", "changes_cursor_invalid", "changes_entry_not_found", "changes_page_too_large", "task_pending_launch",
        "unknown_task", "agent_caller", "caller_undecidable"
    ])
    func givenSyntheticStructuredRefusal_whenRead_thenCodeAndDetailsSurvive(code: String) async {
        // given
        let runner = changesRunner { _ in changesRefusal(code: code, data: .object(["reload": .string("first")])) }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: "task")
        // then
        guard case .failure(let error) = result else { Issue.record("Refusal accepted as listing"); return }
        #expect(error.refusalCode == code && error.refusalData == ["reload": .string("first")])
        #expect(error.isTaskChangesCursorExpired == (code == "changes_cursor_expired"))
    }

    @Test func givenSyntheticRefusalWithoutData_whenTextIsRead_thenCodeSurvives() async {
        // given
        let runner = changesRunner { _ in changesRefusal(code: "changes_entry_not_found") }
        // when
        let result = await changesClient(runner).taskChangesTextChunk(taskID: "task", cursor: "c")
        // then
        guard case .failure(let error) = result else { Issue.record("Refusal accepted as text"); return }
        #expect(error.refusalCode == "changes_entry_not_found" && !error.isTaskChangesCursorExpired)
    }

    @Test func givenSyntheticUsageErrorFromAnOlderEngine_whenRead_thenItIsUnsupported() async {
        // given
        let usage = "{\"error\":{\"code\":\"usage\",\"message\":\"unrecognized arguments: --limit=200\"}}"
        let runner = changesRunner { _ in ProcessOutput(exitCode: 2, stdout: ctlJSON(usage), stderr: "") }
        // when
        let result = await changesClient(runner).taskChangesPage(taskID: "task")
        // then
        guard case .failure(.unsupportedCommand) = result else { Issue.record("Usage error must read as unsupported"); return }
    }

    // MARK: Supersession

    @Test(arguments: ["before", "during"])
    func givenSyntheticGenerationChange_whenReadCompletes_thenTheResponseIsRefused(mode: String) async {
        // given
        let current = TCBox(true)
        let runner = changesRunner { call in
            if call.arguments.first == "task-changes", mode == "during" { current.mutate { $0 = false } }
            return Self.page
        }
        var client = changesClient(runner)
        client.operationIsCurrent = { current.value }
        if mode == "before" { current.mutate { $0 = false } }
        // when
        let result = await client.taskChangesPage(taskID: Doc.taskID)
        // then
        guard case .failure = result else { Issue.record("Obsolete response escaped"); return }
        #expect(runner.calls.count == (mode == "during" ? 1 : 0))
    }

    @Test func givenSyntheticCancelledTask_whenReadCompletes_thenNoCancelledResponseEscapes() async {
        // given
        let runner = changesRunner { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.page
        }
        let client = changesClient(runner)
        // when
        let result = await Task { await client.taskChangesPage(taskID: Doc.taskID) }.value
        // then
        guard case .failure = result else { Issue.record("Cancelled response escaped"); return }
    }
}
