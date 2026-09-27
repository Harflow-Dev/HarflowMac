@testable import MonitorCore
import Testing

@Suite struct EditedFilesTests {

    private func call(_ callID: String, category: String, path: String?, seq: Int) -> TaskEvent {
        var fields = #""call_id":"\#(callID)","tool":"Edit","category":"\#(category)","input_preview":"{}""#
        if let path { fields += #","path":"\#(path)""# }
        return TaskEvent(line: #"{"v":1,"seq":\#(seq),"kind":"tool_call",\#(fields)}"#)!
    }

    private func result(_ callID: String, ok: Bool, seq: Int) -> TaskEvent {
        TaskEvent(line: #"{"v":1,"seq":\#(seq),"kind":"tool_result","call_id":"\#(callID)","ok":\#(ok),"output_tail":""}"#)!
    }

    @Test func givenAnEditCallWithAnOkResult_whenBuilt_thenItIsEdited() {
        // given
        let events = [call("c1", category: "edit", path: "a.swift", seq: 0), result("c1", ok: true, seq: 1)]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .edited)])
    }

    @Test func givenAWriteCallWithAFailedResult_whenBuilt_thenItIsFailed() {
        // given
        let events = [call("c1", category: "write", path: "a.swift", seq: 0), result("c1", ok: false, seq: 1)]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .failed)])
    }

    @Test func givenAnEditCallWithNoResultAtAll_whenBuilt_thenItIsUnconfirmed() {
        // given — vibe emits the tool_call but no tool_result for some call shapes.
        let events = [call("c1", category: "edit", path: "a.swift", seq: 0)]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .unconfirmed)])
    }

    @Test func givenTwoCallsOnTheSamePath_whenBuilt_thenTheLatestCallsOutcomeWins() {
        // given — the first call failed, the second (later) call on the same path succeeded.
        let events = [
            call("c1", category: "edit", path: "a.swift", seq: 0),
            result("c1", ok: false, seq: 1),
            call("c2", category: "edit", path: "a.swift", seq: 2),
            result("c2", ok: true, seq: 3)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .edited)])
    }

    @Test func givenTheLaterCallsResultArrivesBeforeTheEarlierOnesInTheStream_whenBuilt_thenTheLatestCallStillWins() {
        // given — pairing is by call_id, not by stream position, so an out-of-order result for an
        // earlier call must never overwrite the later call's own (still-unconfirmed) status.
        let events = [
            call("c1", category: "edit", path: "a.swift", seq: 0),
            call("c2", category: "edit", path: "a.swift", seq: 1),
            result("c1", ok: true, seq: 2)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then — c2 is the latest call on this path, and its own result never arrived.
        #expect(files == [EditedFile(path: "a.swift", status: .unconfirmed)])
    }

    @Test func givenMultipleDistinctPaths_whenBuilt_thenTheyAppearOnceEachInFirstSeenOrder() {
        // given
        let events = [
            call("c1", category: "edit", path: "b.swift", seq: 0),
            call("c2", category: "write", path: "a.swift", seq: 1),
            call("c3", category: "edit", path: "b.swift", seq: 2),
            result("c1", ok: true, seq: 3),
            result("c2", ok: true, seq: 4),
            result("c3", ok: true, seq: 5)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files.map(\.path) == ["b.swift", "a.swift"])
    }

    @Test func givenReadShellAndMissingPathCalls_whenBuilt_thenTheyAreIgnored() {
        // given
        let events = [
            call("c1", category: "read", path: "a.swift", seq: 0),
            call("c2", category: "shell", path: nil, seq: 1),
            call("c3", category: "edit", path: nil, seq: 2),
            call("c4", category: "edit", path: "", seq: 3)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files.isEmpty)
    }

    @Test func givenAPathUnderTheRepo_whenBuilt_thenItIsShownRepoRelative() {
        // given
        let events = [call("c1", category: "edit", path: "/Users/x/repo/src/a.swift", seq: 0)]
        // when
        let files = EditedFiles.build(from: events, repoPath: "/Users/x/repo")
        // then
        #expect(files == [EditedFile(path: "src/a.swift", status: .unconfirmed)])
    }

    @Test func givenAPathOutsideTheRepo_whenBuilt_thenItIsShownAsIs() {
        // given
        let events = [call("c1", category: "edit", path: "/elsewhere/a.swift", seq: 0)]
        // when
        let files = EditedFiles.build(from: events, repoPath: "/Users/x/repo")
        // then
        #expect(files == [EditedFile(path: "/elsewhere/a.swift", status: .unconfirmed)])
    }

    @Test func givenNoEvents_whenBuilt_thenTheResultIsEmpty() {
        // given / when
        let files = EditedFiles.build(from: [], repoPath: "/Users/x/repo")
        // then — the caller (SummaryPaneModel) is the one that distinguishes an empty result from
        // events being unavailable at all; this helper only ever sees the events it is handed.
        #expect(files.isEmpty)
    }

    // MARK: - Old-log fixtures — logs recorded before this feature landed never upgrade in place

    // (`store.replay_log` replays `ingest`, not `normalize`), so a historical codex edit reads as
    // absent and a historical vibe edit reads as "unconfirmed", never as a false failure.

    @Test func givenAPreChangeCodexLogWithNoFileChangeEvents_whenBuilt_thenNoEditedFilesAppear() {
        // given — codex used to drop `file_change` items outright, so an old log carries only the
        // item types it always normalized (shell, MCP) — never an edit/write `tool_call` at all.
        let events = [
            call("c1", category: "shell", path: nil, seq: 0),
            result("c1", ok: true, seq: 1)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files.isEmpty)
    }

    @Test func givenAPreChangeVibeLogWithCallsButNoResultsAtAll_whenBuilt_thenEveryEditIsUnconfirmed() {
        // given — vibe always turned every effect into a `tool_call`, but before this change it
        // emitted no `tool_result` for any of them, however the effect's own state settled.
        let events = [
            call("c1", category: "edit", path: "a.swift", seq: 0),
            call("c2", category: "write", path: "b.swift", seq: 1)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [
            EditedFile(path: "a.swift", status: .unconfirmed),
            EditedFile(path: "b.swift", status: .unconfirmed)
        ])
    }

    // MARK: - Review-round edge cases

    @Test func givenAnAbsoluteAndARelativeSpellingOfOneFile_whenBuilt_thenItIsOneRowAndTheLatestCallWins() {
        // given — a successful edit via the absolute path, then a failed edit via the relative one.
        let events = [
            call("c1", category: "edit", path: "/repo/a.swift", seq: 0), result("c1", ok: true, seq: 1),
            call("c2", category: "edit", path: "a.swift", seq: 2), result("c2", ok: false, seq: 3)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "/repo")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .failed)])
    }

    @Test func givenACallIDReusedForANewCall_whenTheNewCallHasNoResultYet_thenItIsUnconfirmed() {
        // given
        let events = [
            call("x", category: "edit", path: "a.swift", seq: 0), result("x", ok: true, seq: 1),
            call("x", category: "edit", path: "a.swift", seq: 2)
        ]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .unconfirmed)])
    }

    @Test func givenAResultBeforeAnyCall_whenBuilt_thenItIsIgnored() {
        // given
        let events = [result("c1", ok: true, seq: 0), call("c1", category: "edit", path: "a.swift", seq: 1)]
        // when
        let files = EditedFiles.build(from: events, repoPath: "")
        // then
        #expect(files == [EditedFile(path: "a.swift", status: .unconfirmed)])
    }
}
