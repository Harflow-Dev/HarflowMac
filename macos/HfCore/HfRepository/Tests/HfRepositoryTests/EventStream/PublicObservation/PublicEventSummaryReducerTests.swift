@testable import HfRepository
import MonitorCore
import Testing

// MARK: - PublicEventSummaryReducerTests

@Suite struct PublicEventSummaryReducerTests {
    @Test func givenCompleteChronologicalEdits_whenReplayCatchesUp_thenOnlyObservedCountsAndLatestOutcomesAreExposed() {
        // given
        var reducer = PublicEventSummaryReducer()
        let events = [ObservationFixtures.record(1, "task_started", ["prompt": .string("assignment"), "repo_path": .string("/repo")]),
            ObservationFixtures.call(2, id: "first", path: "/repo/a.swift"), ObservationFixtures.result(3, id: "first", ok: true),
            ObservationFixtures.call(4, id: "second", path: "/repo/a.swift"), ObservationFixtures.result(5, id: "second", ok: false)]
        // when
        reducer.fold(ObservationFixtures.page(events))
        // then
        #expect(reducer.snapshot(caughtUp: false).counts == nil)
        let snapshot = reducer.snapshot(caughtUp: true)
        #expect(snapshot.state == .observed)
        #expect(snapshot.counts?.toolCalls == 2)
        #expect(snapshot.counts?.edits == 2)
        #expect(snapshot.totalFiles == 1)
        #expect(snapshot.files == [EditedFile(path: "a.swift", status: .failed)])
    }

    @Test func givenSeekPages_whenChronologicalReplayFollows_thenSeekDoesNotDoubleCount() {
        // given
        var reducer = PublicEventSummaryReducer()
        let newest = ObservationFixtures.page([ObservationFixtures.call(3, id: "b", path: "b")], older: "older")
        // when
        reducer.noteSeek(newest)
        reducer.fold(ObservationFixtures.page([ObservationFixtures.call(1, id: "a", path: "a")]))
        reducer.fold(newest)
        // then
        #expect(reducer.snapshot(caughtUp: true).counts?.edits == 2)
        #expect(reducer.snapshot(caughtUp: true).totalFiles == 2)
    }

    @Test func givenMissingResultBoolean_whenFolded_thenPartialCertaintyIsDiscarded() {
        // given
        var reducer = PublicEventSummaryReducer()
        let result = ObservationFixtures.record(2, "tool_result", ["call_id": .string("a"), "output_tail": .string("done")])
        // when
        reducer.fold(ObservationFixtures.page([ObservationFixtures.call(1, id: "a", path: "a"), result]))
        // then
        #expect(reducer.snapshot(caughtUp: true).state == .unavailable)
        #expect(reducer.snapshot(caughtUp: true).issues.contains(.unsupportedPayload))
        #expect(reducer.snapshot(caughtUp: true).counts == nil)
        #expect(reducer.snapshot(caughtUp: true).files.isEmpty)
    }

    @Test(arguments: ["future_kind", "missing_text", "truncated", "oversized", "duplicate", "regression", "capture", "skipped"])
    func givenUncertainEvidence_whenFolded_thenNoEmptySuccessIsInvented(reason: String) {
        // given
        var reducer = PublicEventSummaryReducer()
        var raw = ObservationFixtures.record(2)
        if reason == "future_kind" { raw["kind"] = .string("future_kind") }
        if reason == "missing_text" { raw.removeValue(forKey: "text") }
        if reason == "truncated" { raw["truncated"] = .bool(true) }
        if reason == "oversized" { raw["oversized"] = .bool(true) }
        if reason == "duplicate" { raw["seq"] = .number(1) }
        if reason == "regression" { raw["seq"] = .number(0) }
        // when
        reducer.fold(ObservationFixtures.page([ObservationFixtures.record(1), raw],
            capture: reason == "capture" ? "future_capture" : "live", malformed: reason == "skipped" ? 1 : 0))
        // then
        let snapshot = reducer.snapshot(caughtUp: true)
        #expect(snapshot.state == .unavailable)
        #expect(snapshot.counts == nil)
        #expect(snapshot.totalFiles == nil)
        #expect(!snapshot.issues.isEmpty)
    }

    @Test func givenRepositoryKeyBeyondBound_whenTaskStartedIsFolded_thenProjectionIsLimited() {
        // given
        var limits = PublicEventSummaryLimits()
        limits.keyBytes = 3
        var reducer = PublicEventSummaryReducer(limits: limits)
        // when
        reducer.fold(ObservationFixtures.page([ObservationFixtures.record(1, "task_started",
            ["prompt": .string("assignment"), "repo_path": .string("/long")])]))
        // then
        #expect(reducer.snapshot(caughtUp: true).state == .limited)
        #expect(reducer.snapshot(caughtUp: true).counts == nil)
    }

    @Test func givenPublishedFileCap_whenMoreFilesWereObserved_thenTotalRemainsQualifiedAndPublishedKeysAreBounded() {
        // given
        var limits = PublicEventSummaryLimits()
        limits.publishedFiles = 1
        var reducer = PublicEventSummaryReducer(limits: limits)
        // when
        reducer.fold(ObservationFixtures.page([ObservationFixtures.call(1, id: "a", path: "a"),
            ObservationFixtures.call(2, id: "b", path: "b")]))
        // then
        #expect(reducer.snapshot(caughtUp: true).state == .observed)
        #expect(reducer.snapshot(caughtUp: true).totalFiles == 2)
        #expect(reducer.snapshot(caughtUp: true).files.count == 1)
    }

    @Test(arguments: ["files", "pathBytes", "pendingCalls", "callIDBytes", "keyBytes"])
    func givenBoundedProjection_whenOneAdmissionExceedsLimit_thenAllDerivedDataIsDiscarded(cap: String) {
        // given
        var limits = PublicEventSummaryLimits()
        switch cap {
        case "files": limits.files = 1
        case "pathBytes": limits.pathBytes = 1
        case "pendingCalls": limits.pendingCalls = 1
        case "callIDBytes": limits.callIDBytes = 1
        default: limits.keyBytes = 1
        }
        var reducer = PublicEventSummaryReducer(limits: limits)
        // when
        reducer.fold(ObservationFixtures.page([ObservationFixtures.call(1, id: "a", path: "a"),
            ObservationFixtures.call(2, id: "bb", path: "bb")]))
        // then
        let snapshot = reducer.snapshot(caughtUp: true)
        #expect(snapshot.state == .limited)
        #expect(snapshot.issues.contains(.capacity))
        #expect(snapshot.counts == nil)
        #expect(snapshot.files.isEmpty)
    }
}
