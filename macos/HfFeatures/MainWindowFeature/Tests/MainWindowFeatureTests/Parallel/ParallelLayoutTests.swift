import Foundation
@testable import MainWindowFeature
import Testing

/// Monitor piece 12, Design point 3: columns fill the available width instead of a fixed 900pt
/// budget, so there is no leftover band on the right at ordinary window widths.
@Suite struct ParallelLayoutTests {

    // MARK: - Fills available width

    @Test func givenOneMember_whenLayingOutColumns_thenItFillsTheWholeWidthMinusItsDivider() {
        // given / when / then
        #expect(ParallelLayout.columnWidth(memberCount: 1, availableWidth: 800) == 800 - ParallelLayout.dividerWidth)
    }

    @Test func givenTwoMembersWithPlentyOfRoom_whenLayingOutColumns_thenTheyEvenlySplitTheWidth() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 1600)

        // then — (1600 - 2 dividers) / 2, comfortably above the 630 floor: no leftover band.
        #expect(width == (1600 - 2 * ParallelLayout.dividerWidth) / 2)
        #expect(width * 2 + 2 * ParallelLayout.dividerWidth <= 1600)
    }

    @Test func givenTwoMembersAtMinimumViewport_whenLayingOutColumns_thenTheFloorOverflowsForHorizontalScrolling() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 1000)

        // then — each column keeps its 630pt minimum, so the row scrolls horizontally.
        #expect(width == 630)
        #expect(width * 2 + 2 * ParallelLayout.dividerWidth > 1000)
    }

    // MARK: - Keeps the 630 floor

    @Test func givenTooManyMembersForTheWidth_whenLayingOutColumns_thenTheFloorApplies() {
        // given / when / then — 900/10 is far under 630, so the members-count case
        // still keeps its floor even though the rule is width-driven now.
        #expect(ParallelLayout.columnWidth(memberCount: 10, availableWidth: 900) == 630)
    }

    @Test func givenNoAvailableWidthYet_whenLayingOutColumns_thenTheFloorApplies() {
        // given / when / then — a `GeometryReader` reporting 0 before layout has run must not collapse
        // the columns to nothing.
        #expect(ParallelLayout.columnWidth(memberCount: 3, availableWidth: 0) == 630)
    }

    @Test func givenTenAgentsInFullscreen_whenLayingOutColumns_thenChatStaysWideAndOverflowsForHorizontalScrolling() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 10, availableWidth: 2560)
        // then
        #expect(width == 630)
        #expect(width * 10 + ParallelLayout.dividerWidth * 10 > 2560)
    }

    @Test func givenThreeAgentsWithEnoughRoom_whenLayingOutColumns_thenTheyFillTheViewportAboveReadingMinimum() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 2100)
        // then
        #expect(width > ParallelLayout.minimumColumnWidth)
        #expect(width * 3 + ParallelLayout.dividerWidth * 3 == 2100)
    }

    // MARK: - Does not divide by zero

    @Test func givenZeroMembers_whenLayingOutColumns_thenItDoesNotDivideByZero() {
        // given / when / then — `max(1, memberCount)` guards the empty-group edge case.
        #expect(ParallelLayout.columnWidth(memberCount: 0, availableWidth: 900) == 900 - ParallelLayout.dividerWidth)
    }
}
