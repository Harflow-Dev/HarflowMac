import Foundation
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// Headless coverage of how the Summary entry rides the native feed's pure planning layer: row identity, entry order,
/// the update plan on appearance, removal and text change, anchor fallback and the older-page commit rule.
struct ActivityFeedSummaryEntryPlanTests {

    // MARK: Fixtures

    private func row(_ seq: Int) -> ActivityRow { .single(ActivityFixture.text(seq), markdown: nil) }

    private func rows(_ range: ClosedRange<Int>) -> [ActivityRow] { range.map(row) }

    private func summary(_ text: String = "Fixed the retry path.", task: String = "t1") -> ActivityRow {
        let markdown = StreamingMarkdownState().updating(text: text, isStreaming: false)
        return .summary(SummaryEntry(id: SummaryEntry.rowID(taskID: task), taskID: task, text: text, markdown: markdown))
    }

    private func liveTail() -> ActivityFeedTailPresentation {
        .standard(.init(liveStep: .init(text: "Working", indicator: .singleDot)))
    }

    private func approval(_ id: String) -> CallerApprovalCardModel {
        let request = CallerApprovalRequest(raw: [
            "request_id": .string(id), "task_id": .string("t1"), "tool_name": .string("Bash"),
            "cwd": .string("/workspace/repo"), "freedom": .string("write_in_repo"),
            "scope": .string("exact_action_once"), "disposition": .string("pending"),
            "delivery": .string("pending"), "execution_outcome": .string("unknown"),
            "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("swift test")])])
        ])
        return CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request), pending: true, expanded: true,
                                       canRespond: true, notice: nil, submitting: false)
    }

    private func model(_ rows: [ActivityRow], tail: ActivityFeedTailPresentation = .absent,
                       history: EventHistoryState = EventHistoryState(), revision: Int = 0) -> ActivityFeedNativeModel {
        ActivityFeedNativeModel(
            shownRows: rows, allRowIDs: rows.map(\.id), start: nil, emptyText: nil, horizontalPadding: 0, showsPromptBubble: false,
            style: .transcript, expandedGroups: [], tailPresentation: tail, history: history, paginationRevision: revision,
            visible: true, loading: false, approvalReveal: nil, activitySnapshot: nil)
    }

    private func build(_ rows: [ActivityRow], tail: ActivityFeedTailPresentation = .absent) -> [ActivityFeedNativeEntry] {
        ActivityFeedNativeEntries.build(model: model(rows, tail: tail), header: nil, following: false, mountedIDs: [])
    }

    private func plan(_ previous: [ActivityFeedNativeEntry], _ next: [ActivityFeedNativeEntry]) -> ActivityFeedNativePlan {
        ActivityFeedNativePlan.plan(previous: previous, next: next)
    }

    // MARK: Identity

    @Test func givenATask_whenItsSummaryRowIDIsMade_thenItIsTheTaskIDWithASummarySuffix() {
        // given / when
        let id = SummaryEntry.rowID(taskID: "abc12345")
        // then
        #expect(id == "abc12345#summary")
    }

    @Test func givenASummaryRow_whenItsIdentityIsRead_thenIDAndTaskIDComeFromTheEntry() {
        // given
        let row = summary(task: "t7")
        // when / then
        #expect(row.id == "t7#summary")
        #expect(row.taskID == "t7")
    }

    @Test func givenSingleAndGroupRows_whenTheirTaskIDIsRead_thenItMatchesTheirRecords() throws {
        // given
        let single = ActivityRow.single(ActivityFixture.text(1, task: "ta"), markdown: nil)
        let built = ActivityRowsBuilder.build(from: [
            ActivityFixture.tool(2, task: "tb", path: "/a"), ActivityFixture.tool(3, task: "tb", path: "/b")
        ])
        let group = try #require(built.first)
        // when / then
        #expect(single.taskID == "ta")
        #expect(group.taskID == "tb")
    }

    // MARK: Entry order

    @Test func givenApprovalsAndATail_whenEntriesAreBuilt_thenTheSummaryPrecedesThemAndTheBottomSentinelIsLast() {
        // given
        let tail = ActivityFeedTailPresentation.standard(.init(
            liveStep: .init(text: "Working", indicator: .singleDot), approvals: [approval("a1")]))
        // when
        let entries = build(rows(1 ... 3) + [summary()], tail: tail)
        // then
        let ids = entries.map(\.id)
        #expect(ids == ["t1#1", "t1#2", "t1#3", "t1#summary", "activity-approval-a1", "activity-feed-tail", "activity-feed-bottom"])
    }

    // MARK: Plans

    @Test func givenAnEligibleFeed_whenTheSummaryAppears_thenItIsATailInsertBeforeTheSentinel() {
        // given
        let previous = build(rows(1 ... 5))
        // when
        let result = plan(previous, build(rows(1 ... 5) + [summary()]))
        // then
        #expect(result == .tailInsert(removeLeading: 0, insertAt: 5, count: 1))
    }

    @Test func givenATailAndApprovalsOnBothSides_whenTheSummaryAppears_thenTheInsertPrecedesThem() {
        // given
        let tail = ActivityFeedTailPresentation.standard(.init(
            liveStep: .init(text: "Working", indicator: .singleDot), approvals: [approval("a1")]))
        let previous = build(rows(1 ... 5), tail: tail)
        // when
        let result = plan(previous, build(rows(1 ... 5) + [summary()], tail: tail))
        // then
        #expect(result == .tailInsert(removeLeading: 0, insertAt: 5, count: 1))
    }

    @Test func givenTheLiveTailLeavesInTheSameBuild_whenTheSummaryAppears_thenThePlanIsStructural() {
        // given
        let previous = build(rows(1 ... 5), tail: liveTail())
        // when
        let result = plan(previous, build(rows(1 ... 5) + [summary()]))
        // then
        #expect(result == .structural)
    }

    @Test func givenNoRowsBefore_whenTheSummaryIsTheFirstRow_thenThePlanIsStructural() {
        // given
        let previous = build([])
        // when
        let result = plan(previous, build([summary()]))
        // then
        #expect(result == .structural)
    }

    @Test func givenAShownSummary_whenItIsRemoved_thenThePlanIsStructural() {
        // given
        let previous = build(rows(1 ... 5) + [summary()])
        // when
        let result = plan(previous, build(rows(1 ... 5)))
        // then
        #expect(result == .structural)
    }

    @Test func givenAShownSummary_whenItsTextChanges_thenThePlanIsUnchangedButTheEntryDiffers() {
        // given
        let previous = build(rows(1 ... 5) + [summary("First text.")])
        let next = build(rows(1 ... 5) + [summary("Second text.")])
        // when
        let result = plan(previous, next)
        // then
        #expect(result == .unchanged)
        #expect(previous != next, "the changed content must be visible to the table's equality")
        #expect(previous.map(\.id) == next.map(\.id))
    }

    @Test func givenAShownSummary_whenARowIsAppendedBeforeIt_thenThePlanIsNotATailInsert() {
        // given — the follow-up rows replace the entry rather than join the run behind it.
        let previous = build(rows(1 ... 5) + [summary()])
        // when
        let result = plan(previous, build(rows(1 ... 6)))
        // then
        #expect(result == .structural)
    }

    // MARK: Anchor and regroup

    @Test func givenTheSummaryIsTheReadingAnchor_whenItIsRemoved_thenTheAnchorFallsBackToThePreviousRow() {
        // given
        let anchor = ParallelVerticalAnchor(id: "t1#summary", index: 5, relativeOffset: 40)
        let remaining = rows(1 ... 5).map(\.id)
        // when
        let resolved = anchor.resolvedID(in: remaining)
        // then
        #expect(resolved == "t1#5")
    }

    @Test func givenTheSummaryIsTheReadingAnchor_whenItIsRemoved_thenRegroupTransfersNothing() {
        // given
        let old = rows(1 ... 5) + [summary()]
        let anchor = ParallelVerticalAnchor(id: "t1#summary", index: 5, relativeOffset: 40)
        var retained: String? = "t1#3"
        var expanded: Set<String> = []
        // when
        let transferred = ActivityFeedNativeRegroup.transfer(
            anchor: anchor, old: old, next: rows(1 ... 5), retainedFirstID: &retained, expandedGroups: &expanded)
        // then
        #expect(transferred == nil)
        #expect(retained == "t1#3")
        #expect(expanded.isEmpty)
    }

    @Test func givenTheSummaryIsTheAnchor_whenItSurvives_thenRegroupLeavesTheAnchorAlone() {
        // given
        let old = rows(1 ... 5) + [summary("A")]
        let next = rows(1 ... 5) + [summary("B")]
        let anchor = ParallelVerticalAnchor(id: "t1#summary", index: 5, relativeOffset: 12)
        var retained: String?
        var expanded: Set<String> = []
        // when
        let transferred = ActivityFeedNativeRegroup.transfer(
            anchor: anchor, old: old, next: next, retainedFirstID: &retained, expandedGroups: &expanded)
        // then
        #expect(transferred == nil)
    }

    @Test func givenAGroupAnchorAheadOfTheSummary_whenTheGroupIsRegrouped_thenItsReplacementStillResolves() throws {
        // given — the summary row in the old list must not disturb the member lookup.
        let before = ActivityRowsBuilder.build(from: [
            ActivityFixture.tool(2, path: "/b"), ActivityFixture.tool(3, path: "/c")
        ])
        let after = ActivityRowsBuilder.build(from: [
            ActivityFixture.tool(1, path: "/a"), ActivityFixture.tool(2, path: "/b"), ActivityFixture.tool(3, path: "/c")
        ])
        let oldRow = try #require(before.first)
        let newRow = try #require(after.first)
        try #require(oldRow.id != newRow.id)
        let anchor = ParallelVerticalAnchor(id: oldRow.id, index: 0, relativeOffset: 8)
        var retained: String?
        var expanded: Set<String> = []
        // when
        let transferred = ActivityFeedNativeRegroup.transfer(
            anchor: anchor, old: before + [summary()], next: after + [summary()], retainedFirstID: &retained, expandedGroups: &expanded)
        // then
        #expect(transferred?.id == newRow.id)
    }

    // MARK: Older-page request

    private func pending(requested: [ActivityRow]) -> ActivityFeedNativePendingPage {
        ActivityFeedNativePendingPage(requestedIDs: requested.map(\.id), history: EventHistoryState(hasMore: true), paginationRevision: 0)
    }

    @Test func givenAnOutstandingRequest_whenTheSummaryAppearsAtTheNewestEnd_thenTheRequestStaysOutstanding() {
        // given
        let request = pending(requested: rows(1 ... 5))
        // when
        let commit = request.commit(by: model(rows(1 ... 5) + [summary()], history: EventHistoryState(hasMore: true)), observedLoading: false)
        // then
        #expect(commit == nil)
    }

    @Test func givenAnOutstandingRequest_whenOnlyTheSummaryIsWithdrawn_thenTheRequestStaysPending() {
        // given — withdrawing the entry is not older-page evidence.
        let request = pending(requested: rows(1 ... 5) + [summary()])
        // when
        let commit = request.commit(by: model(rows(1 ... 5), history: EventHistoryState(hasMore: true)), observedLoading: false)
        // then
        #expect(commit == nil)
    }

    @Test func givenAnOutstandingRequest_whenTheSummaryIsWithdrawnAndRowsFollow_thenOnlyTheRowsMatter() {
        // given — a follow-up's rows after the withdrawn entry are a live append over the real rows.
        let request = pending(requested: rows(1 ... 5) + [summary()])
        // when
        let commit = request.commit(by: model(rows(1 ... 6), history: EventHistoryState(hasMore: true)), observedLoading: false)
        // then
        #expect(commit == nil)
    }

    @Test func givenAnOutstandingRequest_whenOlderRowsArriveAsTheSummaryIsWithdrawn_thenTheRowsCommit() {
        // given
        let request = pending(requested: rows(3 ... 5) + [summary()])
        // when
        let commit = request.commit(by: model(rows(1 ... 5), history: EventHistoryState(hasMore: true)), observedLoading: false)
        // then
        #expect(commit == .rows)
    }

    @Test func givenIDs_whenSummaryIDsAreStripped_thenOnlyEntryIDsGo() {
        // given / when
        let stripped = SummaryEntry.withoutSummaryIDs(["t1#1", "t1#summary", "t2#3", "t2#summary"])
        // then
        #expect(stripped == ["t1#1", "t2#3"])
        #expect(SummaryEntry.idSuffix == "#summary")
    }

    // MARK: Reading neighbour

    @Test func givenARemovedRow_whenAPrecedingRowSurvives_thenTheNearestPrecedingOneIsChosen() {
        // given
        let old = ["a", "b", "c", "summary"]
        // when / then
        #expect(ActivityFeedNativeReading.neighbour(of: "summary", old: old, surviving: ["a", "b", "c"]) == "c")
        #expect(ActivityFeedNativeReading.neighbour(of: "summary", old: old, surviving: ["a", "b"]) == "b")
    }

    @Test func givenARemovedRow_whenNothingPrecedesIt_thenTheNearestFollowingOneIsChosen() {
        // given
        let old = ["gone", "x", "y"]
        // when / then
        #expect(ActivityFeedNativeReading.neighbour(of: "gone", old: old, surviving: ["y", "x"]) == "x")
        #expect(ActivityFeedNativeReading.neighbour(of: "gone", old: old, surviving: ["y"]) == "y")
    }

    @Test func givenAnIDNotInTheOldList_whenResolved_thenThereIsNoNeighbour() {
        // given / when / then
        #expect(ActivityFeedNativeReading.neighbour(of: "missing", old: ["a", "b"], surviving: ["a", "b"]) == nil)
    }

    @Test func givenNothingSurvives_whenResolved_thenThereIsNoNeighbour() {
        // given / when / then
        #expect(ActivityFeedNativeReading.neighbour(of: "b", old: ["a", "b", "c"], surviving: []) == nil)
        #expect(ActivityFeedNativeReading.neighbour(of: "b", old: ["a", "b", "c"], surviving: ["zzz"]) == nil)
    }

    @Test func givenAnOutstandingRequest_whenOlderRowsArriveWithTheSummary_thenTheRowsCommit() {
        // given
        let request = pending(requested: rows(3 ... 5))
        // when
        let commit = request.commit(by: model(rows(1 ... 5) + [summary()], history: EventHistoryState(hasMore: true)), observedLoading: false)
        // then
        #expect(commit == .rows)
    }
}
