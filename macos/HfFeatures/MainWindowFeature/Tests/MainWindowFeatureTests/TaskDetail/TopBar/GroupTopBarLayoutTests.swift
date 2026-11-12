//
//  GroupTopBarLayoutTests.swift
//  MainWindowFeatureTests
//

import AppKit
import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - GroupTopBarLayoutTests

/// A group's top bar content: the meta is whole or dropped, never shortened, and the default solver is unchanged.
@Suite struct GroupTopBarLayoutTests {
    private typealias Layout = TopBarPrincipalLayout

    @Test(arguments: [320, 400, 480, 560, 700, 900] as [CGFloat])
    func givenAMetaThatMustNotTruncate_whenSolved_thenItIsWholeOrDropped(cap: CGFloat) {
        // given
        let meta: CGFloat = 300

        // when
        let solution = Layout.solve(titleIdeal: 200, metaIdeal: meta, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                    titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)

        // then
        #expect(solution.metaWidth == nil || solution.metaWidth == meta)
        #expect(solution.metaWidth == nil || solution.titleWidth >= GroupTopBarBudget.titleFloor)
        #expect(solution.badgeWidth == nil, "the badge stays whole")
        #expect(solution.metaDropped == (solution.metaWidth == nil))
    }

    @Test func givenRoomForTheTitleFloorAndWholeMeta_whenSolved_thenTheTitleGivesWayAndMetaStaysWhole() {
        // given — 200 pt title, 300 pt meta, fixed 90 + 24, gaps of 8: cap leaves exactly the 160 floor beside the meta.
        let cap: CGFloat = 90 + 24 + 300 + 160 + Layout.spacing * 3

        // when
        let solution = Layout.solve(titleIdeal: 200, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                    titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)

        // then
        #expect(solution.metaWidth == 300)
        #expect(solution.titleWidth == 160)
    }

    @Test func givenOneLessPointThanTheFloorNeeds_whenSolved_thenMetaIsDroppedAndTheTitleReclaimsTheRoom() {
        // given
        let cap: CGFloat = 90 + 24 + 300 + 160 + Layout.spacing * 3 - 1

        // when
        let solution = Layout.solve(titleIdeal: 200, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                    titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)

        // then
        #expect(solution.metaWidth == nil)
        #expect(solution.metaDropped)
        #expect(solution.titleWidth == 200)
    }

    @Test func givenAVeryLongTitle_whenSolvedForAGroup_thenTheTitleTruncatesAtTheTailAndTheBadgeStaysWhole() {
        // given
        let solution = Layout.solve(titleIdeal: 900, metaIdeal: 300, fixed: [90, 24], cap: 500, badgeIndex: 0,
                                    titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)

        // then
        #expect(solution.metaWidth == nil)
        #expect(solution.titleWidth == 500 - 90 - 24 - Layout.spacing * 2)
        #expect(solution.badgeWidth == nil)
    }

    @Test(arguments: [200, 360, 440, 560, 800] as [CGFloat], [nil, 0, 120] as [CGFloat?])
    func givenTaskContent_whenSolvedWithExplicitDefaults_thenTheResultIsIdenticalToTheDefaultCall(cap: CGFloat, meta: CGFloat?) {
        // given / when
        let implicit = Layout.solve(titleIdeal: 250, metaIdeal: meta, fixed: [80, 16, 30], cap: cap, badgeIndex: 0, badgeMinimum: 30)
        let explicit = Layout.solve(titleIdeal: 250, metaIdeal: meta, fixed: [80, 16, 30], cap: cap, badgeIndex: 0, badgeMinimum: 30,
                                    titleFloor: nil, metaMayTruncate: true)

        // then
        #expect(implicit == explicit)
    }

    @Test func givenTheBudget_whenTheDetailColumnGrows_thenTheCapGrowsByTheSameAmountAndNeverGoesNegative() {
        #expect(GroupTopBarBudget.cap(detailWidth: 0) == 0)
        #expect(GroupTopBarBudget.cap(detailWidth: 1016) - GroupTopBarBudget.cap(detailWidth: 736) == 280)
        #expect(GroupTopBarBudget.reservedButtons > GroupTopBarBudget.viewPromptWidth + GroupTopBarBudget.cancelAllWidth)
        #expect(GroupTopBarBudget.cancelAllWidth > GroupTopBarBudget.viewPromptWidth - 40)
    }

    // MARK: - The dot of a dropped meta

    @Test func givenADroppedMeta_whenADotIsReserved_thenItsSlotIsSixteenAndATitleThatFitsKeepsItsWidth() {
        // given — the meta cannot fit; the 120 pt title fits with or without the dot's 16 pt and its gap
        let cap: CGFloat = 90 + 24 + 200 + Layout.spacing * 2

        // when
        let plain = Layout.solve(titleIdeal: 120, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                 titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)
        let withDot = Layout.solve(titleIdeal: 120, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                   titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false, dotWidth: TopBarMetaDotView.side)

        // then
        #expect(TopBarMetaDotView.side == 16)
        #expect(plain.metaDropped && withDot.metaDropped)
        #expect(plain.titleWidth == 120 && withDot.titleWidth == 120)
    }

    @Test func givenADroppedMetaAndATightBudget_whenADotIsReserved_thenTheTitleYieldsExactlyTheDotsSlot() {
        // given
        let cap: CGFloat = 90 + 24 + 150 + Layout.spacing * 2

        // when
        let plain = Layout.solve(titleIdeal: 400, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                 titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)
        let withDot = Layout.solve(titleIdeal: 400, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                   titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false, dotWidth: 16)

        // then
        #expect(plain.titleWidth - withDot.titleWidth == 16 + Layout.spacing)
    }

    @Test func givenAWholeMeta_whenADotIsPassed_thenNothingChanges() {
        // given
        let cap: CGFloat = 90 + 24 + 300 + 160 + Layout.spacing * 3

        // when
        let plain = Layout.solve(titleIdeal: 200, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                 titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false)
        let withDot = Layout.solve(titleIdeal: 200, metaIdeal: 300, fixed: [90, 24], cap: cap, badgeIndex: 0,
                                   titleFloor: GroupTopBarBudget.titleFloor, metaMayTruncate: false, dotWidth: 16)

        // then
        #expect(plain == withDot)
    }

    // MARK: - The dot's popover rules

    @Test func givenHoverAndFocus_whenEscapeDismisses_thenThePopoverStaysHiddenUntilBothLeaveAndOneReturns() {
        // given
        var state = TopBarMetaDotState()
        state.setFocused(true)
        #expect(state.showsPopover)

        // when
        state.dismiss()
        state.setHovering(true)
        state.setHovering(false)

        // then — focus is still there, so it stays dismissed
        #expect(state.showsPopover == false)
        state.setFocused(false)
        #expect(state.showsPopover == false)
        state.setHovering(true)
        #expect(state.showsPopover, "it returns once both left and one came back")
    }

    @Test func givenAnAccessibilityPress_whenFocusLeaves_thenThePopoverCloses() {
        // given
        var state = TopBarMetaDotState()
        state.setFocused(true)
        state.press()
        #expect(state.showsPopover)

        // when
        state.setFocused(false)

        // then — a press never set hover, so nothing keeps the popover open
        #expect(state.isHovering == false)
        #expect(state.showsPopover == false)
    }

    @Test func givenAPress_whenEscapeDismissesIt_thenARefocusShowsItAgain() {
        // given
        var state = TopBarMetaDotState()
        state.setFocused(true)
        state.press()

        // when
        state.dismiss()
        #expect(state.showsPopover == false)
        state.setFocused(false)
        state.setFocused(true)

        // then
        #expect(state.showsPopover)
    }

    @MainActor @Test func givenADotWithoutAWindow_whenPressed_thenFocusIsRefusedAndNothingStaysPressed() {
        // given — no window, so focus cannot be taken
        let dot = TopBarMetaDotView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        dot.sentence = "Enforced for every agent here."

        // when
        let handled = dot.accessibilityPerformPress()

        // then
        #expect(handled == false)
        #expect(dot.state.isPressed == false)
        #expect(dot.state.showsPopover == false)
    }

    @Test func givenAHoveredAndFocusedDot_whenItIsHidden_thenNothingStaysSet() {
        // given
        var state = TopBarMetaDotState()
        state.setHovering(true)
        state.setFocused(true)
        state.press()

        // when
        state.reset()

        // then
        #expect(state == TopBarMetaDotState())
        #expect(state.showsPopover == false)
        state.setFocused(true)
        #expect(state.showsPopover, "it shows again after a fresh focus")
    }
}
