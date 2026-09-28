@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// `TimelinePaneModel.scrollTrigger(for:)` is the pure function behind Follow live's scroll
/// (Review round 1, item 5): a growing stream must re-trigger the scroll even when it only grows
/// the LAST row's own text, never adding a new row — pulled out as a static function so it is
/// directly testable without a SwiftUI rendering harness, the same reasoning as
/// `ParallelColumnModel.visibleRows`.
@Suite struct TimelinePaneModelTests {
    private func textRow(_ id: String, _ text: String, streaming: Bool = false) -> ConversationTimelineRow {
        ConversationTimelineRow(
            id: id, taskID: "t1", timestamp: nil,
            kind: .item(TimelineItem(id: 0, at: nil, body: .text(text, streaming: streaming))), live: true
        )
    }

    @Test func givenTheSameRowsTwice_whenComputingTheTrigger_thenItIsUnchanged() {
        // given
        let rows = [textRow("t1#0", "hello")]
        // when / then
        #expect(TimelinePaneModel.scrollTrigger(for: rows) == TimelinePaneModel.scrollTrigger(for: rows))
    }

    @Test func givenTheLastRowsTextGrows_whenComputingTheTrigger_thenItChangesWithNoNewRow() {
        // given — the same row id, only its text grew (an in-progress streamed reply).
        let before = [textRow("t1#0", "Look")]
        let after = [textRow("t1#0", "Looking at it")]
        // when
        let beforeTrigger = TimelinePaneModel.scrollTrigger(for: before)
        let afterTrigger = TimelinePaneModel.scrollTrigger(for: after)
        // then
        #expect(beforeTrigger != afterTrigger)
    }

    @Test func givenANewRowIsAppended_whenComputingTheTrigger_thenItChanges() {
        // given
        let before = [textRow("t1#0", "hello")]
        let after = before + [textRow("t1#1", "world")]
        // when / then
        #expect(TimelinePaneModel.scrollTrigger(for: before) != TimelinePaneModel.scrollTrigger(for: after))
    }

    @Test func givenNoRows_whenComputingTheTrigger_thenItIsStableAndNeverCrashes() {
        // given / when / then
        #expect(TimelinePaneModel.scrollTrigger(for: []) == TimelinePaneModel.scrollTrigger(for: []))
    }

    @Test func givenTheLastRowIsASeparatorNotAText_whenComputingTheTrigger_thenItStillReflectsRowCount() {
        // given — a turn separator ahead of a follow-up carries no `.text` body to measure.
        let separator = ConversationTimelineRow(id: "sep:t2", taskID: "t2", timestamp: nil, kind: .separator(text: "next"), live: false)
        let before = [textRow("t1#0", "hello")]
        let after = before + [separator]
        // when / then
        #expect(TimelinePaneModel.scrollTrigger(for: before) != TimelinePaneModel.scrollTrigger(for: after))
    }
}
