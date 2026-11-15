import Foundation
@testable import MainWindowFeature
import Testing

/// Monitor piece 12, Design point 3: columns fill the available width instead of a fixed 900pt
/// budget, so there is no leftover band on the right at ordinary window widths.
@Suite struct ParallelLayoutTests {

    // MARK: - Fills available width

    @Test func givenOneLane_whenLayingOutColumns_thenItFillsTheWholeWidth() {
        // given / when / then — no separator follows the last lane.
        #expect(ParallelLayout.columnWidth(memberCount: 1, availableWidth: 800, chrome: .lane) == 800)
    }

    @Test func givenOneInspectorColumn_whenLayingOutColumns_thenItKeepsItsOwnSeparator() {
        // given / when / then — the Graph inspector's single column still draws one divider after itself.
        #expect(ParallelLayout.columnWidth(memberCount: 1, availableWidth: 800, chrome: .inspector) == 800 - ParallelLayout.dividerWidth)
    }

    @Test func givenTwoLanesWithPlentyOfRoom_whenLayingOutColumns_thenTheyEvenlySplitTheWidthLessTheirOneSeparator() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 1600, chrome: .lane)

        // then — (1600 - 1 separator) / 2, comfortably above the 360 floor: the row ends exactly at the viewport's edge.
        #expect(width == (1600 - ParallelLayout.dividerWidth) / 2)
        #expect(ParallelLayout.documentWidth(memberCount: 2, columnWidth: width, chrome: .lane) == 1600)
    }

    @Test(arguments: [1, 2, 3])
    func givenAFittingLaneRow_whenLayingOutColumns_thenTheDocumentFillsTheViewportExactly(count: Int) {
        // given — 3 lanes fit from 1082 pt (3 * 360 + 2 separators).
        for available: CGFloat in [1082, 1200, 1500] {
            // when
            let width = ParallelLayout.columnWidth(memberCount: count, availableWidth: available, chrome: .lane)

            // then
            #expect(ParallelLayout.documentWidth(memberCount: count, columnWidth: width, chrome: .lane) == available,
                    "\(count) lanes in \(available)")
        }
    }

    @Test func givenTwoInspectorColumns_whenLayingOutColumns_thenEachKeepsItsOwnSeparator() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 1600, chrome: .inspector)

        // then — the old formula: (1600 - 2 dividers) / 2.
        #expect(width == (1600 - 2 * ParallelLayout.dividerWidth) / 2)
        #expect(ParallelLayout.documentWidth(memberCount: 2, columnWidth: width, chrome: .inspector) == 1600)
    }

    @Test func givenThreeLanesAtMinimumViewport_whenLayingOutColumns_thenTheFloorOverflowsForHorizontalScrolling() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 736, chrome: .lane)

        // then — each lane keeps its 360pt minimum, so the row scrolls horizontally.
        #expect(width == 360)
        #expect(ParallelLayout.documentWidth(memberCount: 3, columnWidth: width, chrome: .lane) == 3 * 360 + 2 * ParallelLayout.dividerWidth)
        #expect(ParallelLayout.documentWidth(memberCount: 3, columnWidth: width, chrome: .lane) > 736)
    }

    // MARK: - Keeps the 360 floor

    @Test func givenTooManyMembersForTheWidth_whenLayingOutColumns_thenTheFloorApplies() {
        // given / when / then — 900/10 is far under 360, so the members-count case
        // still keeps its floor even though the rule is width-driven now.
        #expect(ParallelLayout.columnWidth(memberCount: 10, availableWidth: 900, chrome: .lane) == 360)
    }

    @Test func givenNoAvailableWidthYet_whenLayingOutColumns_thenTheFloorApplies() {
        // given / when / then — a `GeometryReader` reporting 0 before layout has run must not collapse
        // the columns to nothing.
        #expect(ParallelLayout.columnWidth(memberCount: 3, availableWidth: 0, chrome: .lane) == 360)
        #expect(ParallelLayout.columnWidth(memberCount: 3, availableWidth: 0, chrome: .inspector) == 360)
    }

    @Test func givenTenAgentsInFullscreen_whenLayingOutColumns_thenChatStaysWideAndOverflowsForHorizontalScrolling() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 10, availableWidth: 2560, chrome: .lane)
        // then
        #expect(width == 360)
        #expect(ParallelLayout.documentWidth(memberCount: 10, columnWidth: width, chrome: .lane) > 2560)
    }

    @Test func givenThreeAgentsWithEnoughRoom_whenLayingOutColumns_thenTheyFillTheViewportAboveReadingMinimum() {
        // given / when
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 2100, chrome: .lane)
        // then
        #expect(width > ParallelLayout.minimumColumnWidth)
        #expect(width * 3 + ParallelLayout.dividerWidth * 2 == 2100)
    }

    @Test func givenThreeLanesAtTheDetailWidthOfAMinimumWindow_whenLayingOutLanes_thenTwoWholeLanesAndAPeekShow() {
        // given — a 1000-pt window's 736-pt detail area.
        let width = ParallelLayout.columnWidth(memberCount: 3, availableWidth: 736, chrome: .lane)
        let stride = width + ParallelLayout.dividerWidth

        // when / then — 3 strides less the trailing rule overflow the viewport by 346 points, and the third lane peeks by 14.
        #expect(width == ParallelLayout.minimumColumnWidth)
        #expect(stride == ParallelTestGeometry.laneStride)
        #expect(ParallelLayout.documentWidth(memberCount: 3, columnWidth: width, chrome: .lane) - 736 == 346)
        #expect(736 - 2 * stride == 14)
        #expect(ParallelResidency.visibleIndices(count: 3, offset: 0, width: 736, stride: stride) == 0 ..< 3)
    }

    @Test func givenTheChrome_whenAskingForTheTrailingTrim_thenOnlyALaneRowDropsItsLastSeparator() {
        // given / when / then
        #expect(ParallelLayout.trailingTrim(chrome: .lane) == ParallelLayout.dividerWidth)
        #expect(ParallelLayout.trailingTrim(chrome: .inspector) == 0)
    }

    @Test func givenTheSameColumnWidth_whenMeasuringTheDocument_thenALaneRowIsOneSeparatorShorterThanAnInspectorRow() {
        // given / when
        let lane = ParallelLayout.documentWidth(memberCount: 3, columnWidth: 400, chrome: .lane)
        let inspector = ParallelLayout.documentWidth(memberCount: 3, columnWidth: 400, chrome: .inspector)

        // then
        #expect(inspector == 3 * (400 + ParallelLayout.dividerWidth))
        #expect(lane == inspector - ParallelLayout.dividerWidth)
    }

    @Test func givenOneLane_whenMeasuringTheDocument_thenItHasNoSeparatorAtAll() {
        // given / when / then
        #expect(ParallelLayout.documentWidth(memberCount: 1, columnWidth: 500, chrome: .lane) == 500)
        #expect(ParallelLayout.documentWidth(memberCount: 1, columnWidth: 500, chrome: .inspector) == 501)
    }

    @Test func givenNoInspectorColumns_whenMeasuringTheDocument_thenItIsZeroWide() {
        // given / when / then
        #expect(ParallelLayout.documentWidth(memberCount: 0, columnWidth: 360, chrome: .inspector) == 0)
    }

    @Test func givenTwoLanesOnTheirFloor_whenLayingOutColumns_thenTheFloorWinsOverTheDividedWidth() {
        // given — (700 - 1) / 2 = 349.5 is under the 360 floor.
        // when / then
        #expect(ParallelLayout.columnWidth(memberCount: 2, availableWidth: 700, chrome: .lane) == ParallelLayout.minimumColumnWidth)
        #expect(ParallelLayout.columnWidth(memberCount: 2, availableWidth: 700, chrome: .inspector) == ParallelLayout.minimumColumnWidth)
    }

    @Test func givenTheSameViewport_whenComparingChromes_thenALaneColumnIsHalfASeparatorWiderPerTwoMembers() {
        // given / when
        let lane = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 1600, chrome: .lane)
        let inspector = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 1600, chrome: .inspector)

        // then — 799.5 against 799.
        #expect(lane == 799.5)
        #expect(inspector == 799)
    }

    // MARK: - Leading recovery

    @Test func givenTheSidebarState_whenAskingForTheLeadingRecovery_thenOnlyAnExpandedSidebarRecoversItsMargin() {
        // given / when / then
        #expect(ParallelLayout.floatingSidebarMargin == 8)
        #expect(ParallelLayout.leadingRecovery(sidebarExpanded: true) == 8)
        #expect(ParallelLayout.leadingRecovery(sidebarExpanded: false) == 0)
    }

    // MARK: - Does not divide by zero

    @Test func givenZeroMembers_whenLayingOutColumns_thenItDoesNotDivideByZero() {
        // given / when / then — `max(1, memberCount)` guards the empty-group edge case.
        #expect(ParallelLayout.columnWidth(memberCount: 0, availableWidth: 900, chrome: .lane) == 900)
    }
}
