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

        // then — (1600 - 2 dividers) / 2, comfortably above the 360 floor: no leftover band.
        #expect(width == (1600 - 2 * ParallelLayout.dividerWidth) / 2)
        #expect(width * 2 + 2 * ParallelLayout.dividerWidth <= 1600)
    }

    @Test func givenTwoMembersAtMinimumViewport_whenLayingOutColumns_thenTheFloorOverflowsForHorizontalScrolling() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 736)

        // then — each lane keeps its 360pt minimum, so the row scrolls horizontally.
        #expect(width == 360)
        #expect(width * 3 + 3 * ParallelLayout.dividerWidth > 736)
    }

    // MARK: - Keeps the 360 floor

    @Test func givenTooManyMembersForTheWidth_whenLayingOutColumns_thenTheFloorApplies() {
        // given / when / then — 900/10 is far under 360, so the members-count case
        // still keeps its floor even though the rule is width-driven now.
        #expect(ParallelLayout.columnWidth(memberCount: 10, availableWidth: 900) == 360)
    }

    @Test func givenNoAvailableWidthYet_whenLayingOutColumns_thenTheFloorApplies() {
        // given / when / then — a `GeometryReader` reporting 0 before layout has run must not collapse
        // the columns to nothing.
        #expect(ParallelLayout.columnWidth(memberCount: 3, availableWidth: 0) == 360)
    }

    @Test func givenTenAgentsInFullscreen_whenLayingOutColumns_thenChatStaysWideAndOverflowsForHorizontalScrolling() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 10, availableWidth: 2560)
        // then
        #expect(width == 360)
        #expect(width * 10 + ParallelLayout.dividerWidth * 10 > 2560)
    }

    @Test func givenThreeAgentsWithEnoughRoom_whenLayingOutColumns_thenTheyFillTheViewportAboveReadingMinimum() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 2100)
        // then
        #expect(width > ParallelLayout.minimumColumnWidth)
        #expect(width * 3 + ParallelLayout.dividerWidth * 3 == 2100)
    }

    @Test func givenThreeMembersAtTheDetailWidthOfAMinimumWindow_whenLayingOutLanes_thenTwoWholeLanesAndAPeekShow() {
        // given — a 1000-pt window's 736-pt detail area.
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 736)
        let stride = width + ParallelLayout.dividerWidth

        // when / then — 3 strides overflow the viewport by 347 points, and the third lane peeks by 14.
        #expect(width == ParallelLayout.minimumColumnWidth)
        #expect(stride == ParallelTestGeometry.laneStride)
        #expect(3 * stride - 736 == 347)
        #expect(736 - 2 * stride == 14)
        #expect(ParallelResidency.visibleIndices(count: 3, offset: 0, width: 736, stride: stride) == 0 ..< 3)
    }

    // MARK: - Does not divide by zero

    @Test func givenZeroMembers_whenLayingOutColumns_thenItDoesNotDivideByZero() {
        // given / when / then — `max(1, memberCount)` guards the empty-group edge case.
        #expect(ParallelLayout.columnWidth(memberCount: 0, availableWidth: 900) == 900 - ParallelLayout.dividerWidth)
    }
}
