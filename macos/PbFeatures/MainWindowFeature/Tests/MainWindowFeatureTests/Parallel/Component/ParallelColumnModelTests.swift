@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct ParallelColumnModelTests {
    
    private func items(_ count: Int) -> [TimelineItem] {
        (0 ..< count).map { PreviewFixtures.textItem("step \($0)", seq: $0) }
    }
    
    // MARK: - Last 6 / Show all (MS-SIDE-5/F4-40)
    
    @Test func givenMoreThanSixEvents_whenShown_thenOnlyTheLastSixAppearUntilShowAllIsTapped() {
        // given
        let all = items(9)
        
        // when — not expanded
        let collapsed = ParallelColumnModel.visibleItems(all, showAll: false)
        
        // then
        #expect(collapsed.count == 6)
        #expect(collapsed.map(\.id) == Array(all.suffix(6)).map(\.id))
        
        // when — "Show all" tapped
        let expanded = ParallelColumnModel.visibleItems(all, showAll: true)
        
        // then
        #expect(expanded.count == 9)
        #expect(expanded.map(\.id) == all.map(\.id))
    }
    
    @Test func givenSixOrFewerEvents_whenShown_thenAllOfThemAppearEvenWhenNotExpanded() {
        // given
        let all = items(4)
        
        // when
        let shown = ParallelColumnModel.visibleItems(all, showAll: false)
        
        // then
        #expect(shown.count == 4)
    }
}
