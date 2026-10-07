import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct ParallelColumnModelTests {

    private func rows(_ count: Int) -> [ConversationTimelineRow] {
        (0 ..< count).map { index in
            ConversationTimelineRow(
                id: "t1#\(index)", taskID: "t1", timestamp: nil,
                kind: .item(PreviewFixtures.textItem("step \(index)", seq: index)), live: false
            )
        }
    }

    private func activity(_ count: Int) -> [ActivityRow] {
        ActivityRowsBuilder.build(from: rows(count))
    }

    // MARK: - Last 6 / Show all (MS-SIDE-5/F4-40, Monitor piece 13: counts rows, not items)

    @Test func givenMoreThanSixRows_whenShown_thenOnlyTheLastSixAppearUntilShowAllIsTapped() {
        // given
        let all = activity(9)

        // when — not expanded
        let collapsed = ParallelColumnModel.visibleRows(all, showAll: false)

        // then
        #expect(collapsed.count == ParallelColumnModel.windowSize)
        #expect(collapsed.map(\.id) == Array(all.suffix(6)).map(\.id))

        // when — "Show all" tapped
        let expanded = ParallelColumnModel.visibleRows(all, showAll: true)

        // then
        #expect(expanded.count == 9)
        #expect(expanded.map(\.id) == all.map(\.id))
    }

    @Test func givenSixOrFewerRows_whenShown_thenAllOfThemAppearEvenWhenNotExpanded() {
        // given
        let all = activity(4)

        // when
        let shown = ParallelColumnModel.visibleRows(all, showAll: false)

        // then
        #expect(shown.count == 4)
    }

    @Test func givenASeparatorAmongTheRows_whenCountingSteps_thenTheSeparatorIsExcluded() {
        // given — a follow-up's turn separator is a row but never a "step".
        let all = rows(5) + [
            ConversationTimelineRow(id: "sep:t2", taskID: "t2", timestamp: nil, kind: .separator(text: "go on"), live: false)
        ]

        // when
        let count = ParallelColumnModel.itemCount(all)

        // then
        #expect(count == 5)
    }

    @Test func givenToolCallsFoldedIntoCards_whenWindowing_thenTheWindowCountsCardsNotItems() {
        // given — 10 adjacent reads fold into ONE card, followed by 3 text rows.
        let reads = (0 ..< 10).map { index in
            ConversationTimelineRow(
                id: "t1#r\(index)", taskID: "t1", timestamp: nil,
                kind: .item(PreviewFixtures.toolItem(
                    tool: "Read", category: "read", command: nil, path: "/repo/F\(index).swift", seq: index * 2, callID: "r\(index)"
                )), live: false
            )
        }
        let texts = rows(3)
        let raw = reads + texts
        let activityRows = ActivityRowsBuilder.build(from: raw)

        // when
        let shown = ParallelColumnModel.visibleRows(activityRows, showAll: false)

        // then — the card plus 3 texts all fit the window, and the step count stays the real item count
        #expect(activityRows.count == 4)
        #expect(shown.count == 4)
        #expect(ParallelColumnModel.itemCount(raw) == 13)
    }

    @Test func givenMeasuredShortHistory_whenCellGrowsAndNewActivityArrives_thenOlderRowsRemainUntilSpaceIsNeeded() {
        // given
        let all = activity(12)
        let heights = Dictionary(uniqueKeysWithValues: all.map { ($0.id, CGFloat(20)) })
        // when / then
        let roomy = ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 500, heights: heights)
        #expect(roomy.map(\.id) == all.map(\.id))
        let smaller = ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 300, heights: heights)
        #expect(smaller.count == 8)
        let arrivals = activity(13)
        let awaitingMeasurement = ParallelColumnModel.visibleRows(arrivals, showAll: false, availableHeight: 500,
                                                                  heights: heights, previousFirstID: roomy.first?.id)
        #expect(awaitingMeasurement.first?.id == roomy.first?.id)
        #expect(awaitingMeasurement.count == 13)
        let updatedHeights = Dictionary(uniqueKeysWithValues: arrivals.map { ($0.id, CGFloat(20)) })
        let updated = ParallelColumnModel.visibleRows(arrivals, showAll: false, availableHeight: 500, heights: updatedHeights)
        #expect(updated.count == 13)
        #expect(updated.first?.id == all.first?.id)
    }

    @Test func givenTallRows_whenCellCannotFitMinimum_thenSixRowsRemainScrollable() {
        // given
        let all = activity(10)
        let heights = Dictionary(uniqueKeysWithValues: all.map { ($0.id, CGFloat(180)) })
        // when
        let shown = ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 400, heights: heights)
        // then
        #expect(shown.count == 6)
        #expect(ParallelColumnModel.measurementCandidate(all, shown: shown, availableHeight: 400, heights: heights)?.id == nil)
    }

    @Test func givenUnknownOlderRow_whenMeasuring_thenOneCandidateFillsRemainingSpaceEvenWhenPartiallyVisible() {
        // given
        let all = activity(10)
        let heights = Dictionary(uniqueKeysWithValues: all.suffix(6).map { ($0.id, CGFloat(20)) })
        let shown = ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 500, heights: heights)
        // when
        let candidate = ParallelColumnModel.measurementCandidate(all, shown: shown, availableHeight: 500, heights: heights)
        // then
        #expect(candidate?.id == all[3].id)
        var measured = heights
        measured[all[3].id] = 600
        #expect(ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 500, heights: measured).count == 7)
        let adapted = ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 500, heights: measured)
        #expect(ParallelColumnModel.measurementCandidate(all, shown: adapted,
                                                       availableHeight: 500, heights: measured)?.id == nil)
    }

    @Test func givenReaderAwayFromBottom_whenNewRowsArriveOrCellShrinks_thenOldestVisibleIdentityIsRetained() {
        // given
        let all = activity(12)
        let heights = Dictionary(uniqueKeysWithValues: all.map { ($0.id, CGFloat(20)) })
        // when
        let shown = ParallelColumnModel.visibleRows(all, showAll: false, availableHeight: 100,
                                                   heights: heights, retainedFirstID: all[2].id)
        // then
        #expect(shown.map(\.id) == Array(all[2...]).map(\.id))
        #expect(ParallelColumnModel.visibleRows(all, showAll: true, availableHeight: 100, heights: heights).count == 12)
    }

    // MARK: - Subtitle

    @Test func givenASingleTurnConversation_whenBuildingTheSubtitle_thenItIsRepoAndBackendOnly() {
        // given / when
        let subtitle = ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/polybridge/", backend: "claude", turns: 1)

        // then
        #expect(subtitle == "polybridge · Claude")
    }

    @Test func givenAMultiTurnConversation_whenBuildingTheSubtitle_thenTheTurnCountIsAppended() {
        // given / when
        let subtitle = ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/polybridge", backend: "codex", turns: 3)

        // then
        #expect(subtitle == "polybridge · Codex · 3 turns")
    }
}
