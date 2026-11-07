import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// Headless plan coverage for the live-append tail insert. Every entry list comes from the
/// production `ActivityFeedNativeEntries.build`, so the bottom sentinel, header, approvals and
/// tail are real. `case tailInsert(removeLeading: Int, insertAt: Int, count: Int)`: `removeLeading`
/// is the number of leading table entries removed from `previous` (a lost header counts),
/// `insertAt` is the index in post-removal coordinates at which `count` entries of `next` are
/// inserted, and the first trailing non-row entry (approval, tail or bottom) sits at `insertAt`.
struct ActivityFeedNativeTailInsertPlanTests {

    // MARK: Fixtures

    private func row(_ seq: Int) -> ActivityRow {
        .single(ActivityFixture.text(seq), markdown: nil)
    }

    private func rows(_ range: ClosedRange<Int>) -> [ActivityRow] { range.map(row) }

    private func approvalCard(_ id: String) -> CallerApprovalCardModel {
        let request = CallerApprovalRequest(raw: [
            "request_id": .string(id), "task_id": .string("t1"), "tool_name": .string("Bash"),
            "cwd": .string("/workspace/repo"), "freedom": .string("write_in_repo"),
            "scope": .string("exact_action_once"), "disposition": .string("pending"),
            "delivery": .string("pending"), "execution_outcome": .string("unknown"),
            "action": .object(["tool_name": .string("Bash"),
                               "input": .object(["command": .string("swift test")])])
        ])
        return CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request),
                                       pending: true, expanded: true, canRespond: true,
                                       notice: nil, submitting: false)
    }

    private func liveTail(approvals: [CallerApprovalCardModel] = [], withLiveStep: Bool = true)
        -> ActivityFeedTailPresentation {
        .standard(.init(liveStep: withLiveStep ? .init(text: "Working", indicator: .singleDot) : nil,
                        approvals: approvals))
    }

    private func build(_ rows: [ActivityRow], header: ActivityFeedNativeEntry.Header? = nil,
                       tail: ActivityFeedTailPresentation = .absent) -> [ActivityFeedNativeEntry] {
        let model = ActivityFeedNativeModel(
            shownRows: rows, allRowIDs: rows.map(\.id), start: nil, emptyText: nil, horizontalPadding: 0,
            showsPromptBubble: false, expandedGroups: [], tailPresentation: tail, history: EventHistoryState(),
            paginationRevision: 0, visible: true, loading: false, approvalReveal: nil, activitySnapshot: nil)
        return ActivityFeedNativeEntries.build(model: model, header: header, following: false, mountedIDs: [])
    }

    private func plan(_ previous: [ActivityFeedNativeEntry], _ next: [ActivityFeedNativeEntry]) -> ActivityFeedNativePlan {
        ActivityFeedNativePlan.plan(previous: previous, next: next)
    }

    private func isStructural(_ plan: ActivityFeedNativePlan) -> Bool { plan == .structural }

    // MARK: - Unchanged and structural plans

    @Test func givenBuiltEntries_whenRebuiltFromSameRows_thenUnchanged() {
        // given / when
        let result = plan(build(rows(1 ... 50)), build(rows(1 ... 50)))
        // then
        #expect(result == .unchanged)
    }

    @Test func givenBuiltEntriesWithFirstRowSpacing_whenWindowSlidesWithoutHeader_thenNewFirstRowHasTwelvePointSpacing() {
        // given
        let previous = build(rows(2 ... 101))
        let next = build(rows(3 ... 102))
        // when
        let spacing: (ActivityFeedNativeEntry) -> CGFloat = \.topSpacing
        // then — the surviving row that became first changes spacing from 20 to 12, which the
        // transaction must re-measure even though its id is unchanged.
        let before = previous.first { $0.id == "t1#3" }.map(spacing)
        let after = next.first { $0.id == "t1#3" }.map(spacing)
        #expect(before == 20)
        #expect(after == 12)
    }

    @Test func givenHeldLoadingHeader_whenRowAppended_thenStructural() {
        // given — every header case shares one id, so a held `.loading` cannot be matched by id.
        let previous = build(rows(1 ... 50), header: .loading)
        // when
        let result = plan(previous, build(rows(1 ... 51), header: .loading))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenHeldLoadingHeader_whenWindowSlides_thenStructural() {
        // given / when
        let result = plan(build(rows(1 ... 100), header: .loading), build(rows(2 ... 101), header: .loading))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenBeginningHeader_whenItBecomesLoadingWithAppendedRow_thenStructural() {
        // given — same header id, different case: id comparison alone would call this unchanged.
        let previous = build(rows(1 ... 50), header: .beginning)
        // when
        let result = plan(previous, build(rows(1 ... 51), header: .loading))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenBeginningHeader_whenItBecomesLoadingWithSameRows_thenUnchanged() {
        // given — header cases share one id, so the entry ids are identical.
        let previous = build(rows(1 ... 50), header: .beginning)
        // when
        let result = plan(previous, build(rows(1 ... 50), header: .loading))
        // then
        #expect(result == .unchanged, "plan was \(result)")
    }

    @Test func givenHeldErrorHeader_whenRowAppended_thenStructural() {
        // given
        let previous = build(rows(1 ... 50), header: .error("offline"))
        // when
        let result = plan(previous, build(rows(1 ... 51), header: .error("offline")))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenNoHeader_whenLoadingHeaderAppearsWithAppendedRow_thenStructural() {
        // given
        let previous = build(rows(1 ... 50))
        // when
        let result = plan(previous, build(rows(1 ... 51), header: .loading))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenInteriorIDEditAlongsideAppend_whenPlanned_thenStructural() {
        // given
        var nextRows = rows(1 ... 51)
        nextRows[24] = row(900)
        // when
        let result = plan(build(rows(1 ... 50)), build(nextRows))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenReorderedRowsAlongsideAppend_whenPlanned_thenStructural() {
        // given
        var nextRows = rows(1 ... 51)
        nextRows.swapAt(10, 11)
        // when
        let result = plan(build(rows(1 ... 50)), build(nextRows))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenRegroupedRows_whenPlanned_thenStructural() {
        // given — two rows collapse into one card id in the interior, plus a new tail row.
        var nextRows = rows(1 ... 51)
        nextRows.replaceSubrange(9 ... 10, with: [row(901)])
        // when
        let result = plan(build(rows(1 ... 50)), build(nextRows))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenWindowSlideWithInteriorEdit_whenPlanned_thenStructural() {
        // given — the leading row leaves, but row 50 is also replaced.
        var nextRows = rows(2 ... 101)
        nextRows[48] = row(902)
        // when
        let result = plan(build(rows(1 ... 100)), build(nextRows))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenZeroRowsBefore_whenRowsArrive_thenStructural() {
        // given — tail and bottom only.
        let tail = liveTail()
        // when
        let result = plan(build([], tail: tail), build(rows(1 ... 1), tail: tail))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenZeroRowsAfter_whenRowsDisappear_thenStructural() {
        // given
        let tail = liveTail()
        // when
        let result = plan(build(rows(1 ... 3), tail: tail), build([], tail: tail))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenZeroRowsBothSidesWithChangedTail_whenPlanned_thenNotInsert() {
        // given — no row run on either side: only the tail appears.
        let result = plan(build([]), build([], tail: liveTail()))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenTrailingEntriesChangeWithAppend_whenPlanned_thenStructural() {
        // given — a tail appears at the same time as the new row: trailing ids differ.
        let previous = build(rows(1 ... 50))
        // when
        let result = plan(previous, build(rows(1 ... 51), tail: liveTail()))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenApprovalSetChangesWithAppend_whenPlanned_thenStructural() {
        // given
        let previous = build(rows(1 ... 50), tail: liveTail(approvals: [approvalCard("a1")]))
        let next = build(rows(1 ... 51), tail: liveTail(approvals: [approvalCard("a1"), approvalCard("a2")]))
        // when
        let result = plan(previous, next)
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenRowsRemovedFromTheEnd_whenPlanned_thenStructural() {
        // given / when
        let result = plan(build(rows(1 ... 50)), build(rows(1 ... 49)))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    @Test func givenOlderRowsPrepended_whenPlanned_thenStructural() {
        // given — a page of older history revealed above the current rows.
        let result = plan(build(rows(51 ... 100)), build(rows(1 ... 100)))
        // then
        #expect(isStructural(result), "plan was \(result)")
    }

    // MARK: - Tail insert payloads

    private func ids(_ entries: [ActivityFeedNativeEntry]) -> [String] { entries.map(\.id) }

    /// Replays a tail insert on the previous ids in the table's own order of operations: remove the
    /// leading run, then insert `count` next entries at `insertAt` in post-removal coordinates.
    private func replay(_ plan: ActivityFeedNativePlan, previous: [ActivityFeedNativeEntry],
                        next: [ActivityFeedNativeEntry]) -> [String]? {
        guard case .tailInsert(let removeLeading, let insertAt, let count) = plan,
              removeLeading <= previous.count else { return nil }
        var result = Array(ids(previous).dropFirst(removeLeading))
        guard insertAt >= 0, insertAt <= result.count, insertAt + count <= next.count else { return nil }
        result.insert(contentsOf: ids(next)[insertAt ..< insertAt + count], at: insertAt)
        return result
    }

    private func expectTailInsert(_ previous: [ActivityFeedNativeEntry], _ next: [ActivityFeedNativeEntry],
                                  removeLeading: Int, insertAt: Int, count: Int) {
        let result = plan(previous, next)
        #expect(result == .tailInsert(removeLeading: removeLeading, insertAt: insertAt, count: count))
        #expect(replay(result, previous: previous, next: next) == ids(next), "payload does not reproduce next")
    }

    @Test func givenBuiltEntries_whenOneRowAppended_thenTailInsertBeforeBottomSentinel() {
        // given
        let previous = build(rows(1 ... 50))
        // when / then.
        expectTailInsert(previous, build(rows(1 ... 51)), removeLeading: 0, insertAt: 50, count: 1)
    }

    @Test func givenApprovalsAndTailPresent_whenRowAppended_thenInsertGoesBeforeApprovals() {
        // given
        let tail = liveTail(approvals: [approvalCard("a1"), approvalCard("a2")])
        let previous = build(rows(1 ... 50), tail: tail)
        // when / then — entries are rows, approval a1, approval a2, tail, bottom.
        expectTailInsert(previous, build(rows(1 ... 51), tail: tail), removeLeading: 0, insertAt: 50, count: 1)
        #expect(previous[50].id == "activity-approval-a1")
    }

    @Test func givenTailWithoutApprovals_whenRowAppended_thenInsertGoesBeforeTail() {
        // given
        let tail = liveTail()
        let previous = build(rows(1 ... 50), tail: tail)
        // when / then
        expectTailInsert(previous, build(rows(1 ... 51), tail: tail), removeLeading: 0, insertAt: 50, count: 1)
        #expect(previous[50].id == "activity-feed-tail")
    }

    @Test func givenSeveralRowsAppended_whenPlanned_thenOneTailInsertCoversThemAll() {
        // given / when / then
        expectTailInsert(build(rows(1 ... 50)), build(rows(1 ... 53)), removeLeading: 0, insertAt: 50, count: 3)
    }

    @Test func givenBeginningHeaderBothSides_whenRowAppended_thenTailInsertAfterHeaderOffset() {
        // given / when / then — header is entry 0, so the sentinel sits at 51.
        expectTailInsert(build(rows(1 ... 50), header: .beginning), build(rows(1 ... 51), header: .beginning),
                         removeLeading: 0, insertAt: 51, count: 1)
    }

    @Test func givenFullWindowWithoutHeader_whenWindowSlidesByOne_thenRemoveOneLeadingAndInsertOneTrailing() {
        // given / when / then
        expectTailInsert(build(rows(2 ... 101)), build(rows(3 ... 102)), removeLeading: 1, insertAt: 99, count: 1)
    }

    @Test func givenExactlyFullWindowWithBeginningHeader_whenFirstSlideLosesHeader_thenHeaderAndFirstRowLeave() {
        // given / when / then — header plus row 1 leave; row 101 arrives.
        expectTailInsert(build(rows(1 ... 100), header: .beginning), build(rows(2 ... 101)),
                         removeLeading: 2, insertAt: 99, count: 1)
    }

    @Test func givenSlideByThreeRows_whenPlanned_thenRemoveThreeAndInsertThree() {
        // given / when / then
        expectTailInsert(build(rows(1 ... 100)), build(rows(4 ... 103)), removeLeading: 3, insertAt: 97, count: 3)
    }

    @Test func givenSlideWithApprovalsAndTail_whenPlanned_thenInsertPrecedesApprovals() {
        // given
        let tail = liveTail(approvals: [approvalCard("a1")])
        let previous = build(rows(2 ... 101), tail: tail)
        // when / then
        expectTailInsert(previous, build(rows(3 ... 102), tail: tail), removeLeading: 1, insertAt: 99, count: 1)
        #expect(previous[100].id == "activity-approval-a1")
    }

    @Test func givenPinnedBoundaryBeyondPageSize_whenRowAppended_thenPlainTailInsertWithoutRemoval() {
        // given / when / then — 101 rows are shown because the boundary is retained.
        expectTailInsert(build(rows(5 ... 105)), build(rows(5 ... 106)), removeLeading: 0, insertAt: 101, count: 1)
    }

    @Test func givenShortFeedWithBeginningHeaderBothSides_whenRowAppended_thenHeaderMatchedByCase() {
        // given — a header kept across an append is compared by case, never by its shared id.
        let previous = build(rows(1 ... 5), header: .beginning)
        // when
        let result = plan(previous, build(rows(1 ... 6), header: .beginning))
        // then
        #expect(result == .tailInsert(removeLeading: 0, insertAt: 6, count: 1))
    }

    @Test func givenTailInsertPlan_whenComparedWithOtherOutcomes_thenDistinct() {
        // given
        let insert = ActivityFeedNativePlan.tailInsert(removeLeading: 0, insertAt: 50, count: 1)
        // then
        #expect(insert != .unchanged)
        #expect(insert != .structural)
        #expect(insert != .tailInsert(removeLeading: 1, insertAt: 50, count: 1))
        #expect(insert != .tailInsert(removeLeading: 0, insertAt: 49, count: 1))
        #expect(insert != .tailInsert(removeLeading: 0, insertAt: 50, count: 2))
    }
}
