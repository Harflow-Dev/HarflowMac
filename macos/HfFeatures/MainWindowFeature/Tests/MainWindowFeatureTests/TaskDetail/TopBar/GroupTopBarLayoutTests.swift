//
//  GroupTopBarLayoutTests.swift
//  MainWindowFeatureTests
//

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
}
