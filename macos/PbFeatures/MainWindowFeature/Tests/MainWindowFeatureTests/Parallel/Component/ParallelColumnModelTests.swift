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

    // MARK: - Last 6 / Show all (MS-SIDE-5/F4-40, Monitor piece 13: counts rows, not items)

    @Test func givenMoreThanSixRows_whenShown_thenOnlyTheLastSixAppearUntilShowAllIsTapped() {
        // given
        let all = rows(9)

        // when — not expanded
        let collapsed = ParallelColumnModel.visibleRows(all, showAll: false)

        // then
        #expect(collapsed.count == 6)
        #expect(collapsed.map(\.id) == Array(all.suffix(6)).map(\.id))

        // when — "Show all" tapped
        let expanded = ParallelColumnModel.visibleRows(all, showAll: true)

        // then
        #expect(expanded.count == 9)
        #expect(expanded.map(\.id) == all.map(\.id))
    }

    @Test func givenSixOrFewerRows_whenShown_thenAllOfThemAppearEvenWhenNotExpanded() {
        // given
        let all = rows(4)

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
}
