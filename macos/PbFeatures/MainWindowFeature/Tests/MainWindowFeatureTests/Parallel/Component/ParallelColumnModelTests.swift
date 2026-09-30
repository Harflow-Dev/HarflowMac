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
