@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// `ActivityUpdateToken` is the pure value behind Follow live's scroll: it must move when the feed
/// grows or changes in place (Review round 1, item 5 — a stream growing inside the last row, plus a
/// tool result landing inside a card), and is derived from the rows alone so a card being expanded
/// or collapsed — view state — can never scroll the feed.
@Suite struct TimelinePaneModelTests {
    typealias Fixture = ActivityFixture

    private func token(_ rows: [ConversationTimelineRow]) -> ActivityUpdateToken {
        ActivityUpdateToken(rows: rows, liveStep: LiveStep(rows: rows))
    }

    @Test func givenTheSameRowsTwice_whenComputingTheToken_thenItIsUnchanged() {
        // given
        let rows = [Fixture.text(1, "hello"), Fixture.tool(2, path: "/a")]
        // when / then
        #expect(token(rows) == token(rows))
    }

    @Test func givenTheLastRowsTextGrows_whenComputingTheToken_thenItChangesWithNoNewRow() {
        // given — the same row id, only its text grew (an in-progress streamed reply).
        let before = [Fixture.text(1, "Look", streaming: true)]
        let after = [Fixture.text(1, "Looking at it", streaming: true)]
        // when / then
        #expect(token(before) != token(after))
        #expect(token(before).rowCount == token(after).rowCount)
    }

    @Test func givenAStreamingReplyCompletes_whenComputingTheToken_thenItChanges() {
        #expect(token([Fixture.text(1, "done", streaming: true)]) != token([Fixture.text(1, "done", streaming: false)]))
    }

    @Test func givenANewRowIsAppended_whenComputingTheToken_thenItChanges() {
        // given
        let before = [Fixture.text(1, "hello")]
        // when / then
        #expect(token(before) != token(before + [Fixture.text(2, "world")]))
    }

    @Test func givenAGroupGrowsByOneCall_whenComputingTheToken_thenItChanges() {
        // given — a new call folds into the existing card: no new feed row, but the feed changed.
        let before = [Fixture.tool(1, path: "/a")]
        let after = before + [Fixture.tool(2, path: "/b")]
        // when
        let beforeRows = ActivityRowsBuilder.build(from: before)
        let afterRows = ActivityRowsBuilder.build(from: after)
        // then
        #expect(beforeRows.count == afterRows.count)
        #expect(token(before) != token(after))
    }

    @Test func givenAPendingCallGetsItsResult_whenComputingTheToken_thenItChangesInPlace() {
        // given
        let before = [Fixture.tool(1, path: "/a", resolved: false)]
        let after = [Fixture.tool(1, path: "/a", resolved: true)]
        // when / then
        #expect(token(before) != token(after))
    }

    @Test func givenAResultFlipsFromOkToFailed_whenComputingTheToken_thenItChanges() {
        #expect(token([Fixture.tool(1, path: "/a", ok: true)]) != token([Fixture.tool(1, path: "/a", ok: false)]))
    }

    @Test func givenTheLiveStepMoves_whenComputingTheToken_thenItChanges() {
        // given
        let first = [Fixture.tool(1, path: "/a", resolved: false)]
        let second = [Fixture.tool(1, path: "/b", resolved: false)]
        // when / then
        #expect(token(first) != token(second))
    }

    @Test func givenNoRows_whenComputingTheToken_thenItIsStableAndNeverCrashes() {
        #expect(token([]) == token([]))
        #expect(token([]) == ActivityUpdateToken.empty)
    }

    @Test func givenTheLastRowIsASeparator_whenComputingTheToken_thenItStillReflectsRowCount() {
        // given — a turn separator carries no `.text` body to measure.
        let before = [Fixture.text(1, "hello")]
        let after = before + [Fixture.separator("next", task: "t2")]
        // when / then
        #expect(token(before) != token(after))
    }

    @Test func givenAModelBuiltFromRows_whenExpansionWouldToggle_thenTheTokenIsUnaffected() {
        // given — expansion is view state keyed by group id; the model (and so the token) never sees it.
        let rows = [Fixture.tool(1, path: "/a"), Fixture.tool(2, path: "/b")]
        let first = TimelinePaneModel(stepCountText: "2 steps", rows: rows, start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)
        let second = TimelinePaneModel(stepCountText: "2 steps", rows: rows, start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)
        // when / then
        #expect(first.updateToken == second.updateToken)
        #expect(first.activityRows.first?.id == second.activityRows.first?.id)
    }
}
