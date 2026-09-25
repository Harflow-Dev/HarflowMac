@testable import MainWindowFeature
import Testing

@Suite struct ParallelLayoutTests {
    
    // MARK: - Column width (F4-40)
    
    @Test func givenNMembers_whenLayingOutColumns_thenEachIsAtLeast360WideAndTotals900OverN() {
        // given / when / then
        #expect(ParallelLayout.columnWidth(memberCount: 1) == 900)
        #expect(ParallelLayout.columnWidth(memberCount: 2) == 450)
        #expect(ParallelLayout.columnWidth(memberCount: 3) == 360) // 900/3 == 300 < 360, so the floor applies
        #expect(ParallelLayout.columnWidth(memberCount: 10) == 360)
    }
    
    @Test func givenZeroMembers_whenLayingOutColumns_thenItDoesNotDivideByZero() {
        // given / when / then — `max(1, memberCount)` guards the empty-group edge case.
        #expect(ParallelLayout.columnWidth(memberCount: 0) == 900)
    }
}
