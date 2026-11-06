import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// Headless coverage of the pure entry-diff plan: no window, hosting view or application state.
/// Limit: the append cases use entries without the trailing bottom sentinel. `build` always ends
/// its list with that sentinel, so a real row append currently plans `.structural`, and these
/// tests do not establish that live appends avoid a table reload.
struct ActivityFeedNativePlanTests {
    private func entry(_ seq: Int, topSpacing: CGFloat = 20, fade: Bool = false) -> ActivityFeedNativeEntry {
        .row(ActivityFeedNativeEntry.Row(
            row: .single(ActivityFixture.text(seq), markdown: nil), isExpanded: false, fade: fade,
            topSpacing: topSpacing))
    }

    private func entries(_ range: ClosedRange<Int>) -> [ActivityFeedNativeEntry] {
        range.map { entry($0) }
    }

    private func model(rows: [ActivityRow]) -> ActivityFeedNativeModel {
        ActivityFeedNativeModel(
            shownRows: rows, allRowIDs: rows.map(\.id), start: nil, emptyText: nil, horizontalPadding: 0,
            showsPromptBubble: false, expandedGroups: [], tailPresentation: .absent, history: EventHistoryState(),
            paginationRevision: 0, visible: true, loading: false, approvalReveal: nil, activitySnapshot: nil)
    }

    private func built(count: Int) -> [ActivityFeedNativeEntry] {
        let rows = (1 ... count).map { ActivityRow.single(ActivityFixture.text($0), markdown: nil) }
        return ActivityFeedNativeEntries.build(model: model(rows: rows), header: nil, following: false, mountedIDs: [])
    }

    @Test func givenIdenticalEntries_whenPlanned_thenUnchanged() {
        // given
        let previous = entries(1 ... 5)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: previous)
        // then
        #expect(plan == .unchanged)
    }

    @Test func givenSameIDsWithRefreshedContent_whenPlanned_thenUnchanged() {
        // given — spacing and fade differ, ids do not.
        let previous = entries(1 ... 3)
        let next = [entry(1, topSpacing: 12), entry(2, fade: true), entry(3)]
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then
        #expect(plan == .unchanged)
    }

    @Test func givenBothEmpty_whenPlanned_thenUnchanged() {
        // given / when
        let plan = ActivityFeedNativePlan.plan(previous: [], next: [])
        // then
        #expect(plan == .unchanged)
    }

    @Test func givenAppendedEntries_whenPlanned_thenAppendWithPreviousAsExactPrefix() {
        // given
        let previous = entries(1 ... 4)
        let next = entries(1 ... 6)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then — the appended range is exactly the entries after the previous count.
        #expect(plan == .append)
        #expect(Array(next.map(\.id).prefix(previous.count)) == previous.map(\.id))
        #expect(next.dropFirst(previous.count).map(\.id) == ["t1#5", "t1#6"])
    }

    @Test func givenSingleAppendedEntry_whenPlanned_thenAppend() {
        // given / when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 1), next: entries(1 ... 2))
        // then
        #expect(plan == .append)
    }

    @Test func givenEmptyPrevious_whenEntriesArrive_thenStructural() {
        // given / when
        let plan = ActivityFeedNativePlan.plan(previous: [], next: entries(1 ... 3))
        // then — there is nothing to append to.
        #expect(plan == .structural)
    }

    @Test func givenAllEntriesRemoved_whenPlanned_thenStructural() {
        // given / when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 3), next: [])
        // then
        #expect(plan == .structural)
    }

    @Test func givenPrependedEntries_whenPlanned_thenStructuralNotAppend() {
        // given
        let previous = entries(3 ... 5)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: entries(1 ... 5))
        // then
        #expect(plan == .structural)
    }

    @Test func givenRemovedTrailingEntry_whenPlanned_thenStructural() {
        // given / when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 4), next: entries(1 ... 3))
        // then
        #expect(plan == .structural)
    }

    @Test func givenRemovedInteriorEntry_whenPlanned_thenStructural() {
        // given
        let next = [entry(1), entry(3), entry(4)]
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 4), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenReorderedEntries_whenPlanned_thenStructural() {
        // given
        let next = [entry(2), entry(1), entry(3)]
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 3), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenReorderedEntriesWithAppend_whenPlanned_thenStructural() {
        // given
        let next = [entry(2), entry(1), entry(3), entry(4)]
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 3), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenInteriorIDEditWithAppend_whenPlanned_thenStructuralNotAppend() {
        // given — an interior entry is replaced while the list also grows.
        let next = [entry(1), entry(9), entry(3), entry(4)]
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 3), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenInteriorIDEditAtSameCount_whenPlanned_thenStructural() {
        // given
        let next = [entry(1), entry(9), entry(3)]
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 3), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenHeaderAddedAtTop_whenPlanned_thenStructural() {
        // given
        let next = [ActivityFeedNativeEntry.header(.loading)] + entries(1 ... 3)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 3), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenLargeList_whenOneEntryAppended_thenAppendIsPlanned() {
        // given
        let previous = entries(1 ... 5_000)
        let next = entries(1 ... 5_001)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then
        #expect(plan == .append)
        #expect(next.count - previous.count == 1)
    }

    @Test func givenLargeList_whenIdenticalUpdate_thenUnchanged() {
        // given
        let previous = entries(1 ... 5_000)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: entries(1 ... 5_000))
        // then
        #expect(plan == .unchanged)
    }

    @Test func givenLargeList_whenFirstEntryChanges_thenStructural() {
        // given
        var next = entries(1 ... 5_001)
        next[0] = entry(0)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: entries(1 ... 5_000), next: next)
        // then
        #expect(plan == .structural)
    }

    @Test func givenBuiltEntriesForSameRows_whenPlanned_thenUnchanged() {
        // given — entries from the production builder, rebuilt from identical input.
        let previous = built(count: 50)
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: built(count: 50))
        // then
        #expect(plan == .unchanged)
    }
}
