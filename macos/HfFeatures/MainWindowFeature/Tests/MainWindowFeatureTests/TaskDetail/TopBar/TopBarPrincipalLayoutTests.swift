//
//  TopBarPrincipalLayoutTests.swift
//  MainWindowFeatureTests
//

import AppKit
import CoreGraphics
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

// MARK: - TopBarPrincipalLayoutTests

/// The pure solver: the title truncates first, the title never goes below 80 while meta shows, and meta is dropped
/// rather than drawn narrower than 60.
@MainActor @Suite struct TopBarPrincipalLayoutTests {
    private typealias Layout = TopBarPrincipalLayout

    /// Badge, busy slot and connection status.
    private nonisolated static let fixed: [CGFloat] = [90, 16, 24]
    private nonisolated static let caps: [CGFloat] = [360, 440, 560]
    private nonisolated static let metaIdeal: CGFloat = 150
    /// Approximate ideal widths of 9, 41 and 120 character titles.
    private nonisolated static let short: CGFloat = 63
    private nonisolated static let medium: CGFloat = 287
    private nonisolated static let long: CGFloat = 840

    private func gaps(_ parts: Int) -> CGFloat { Layout.spacing * CGFloat(parts - 1) }

    /// What is left for title and meta after the fixed parts and every gap.
    private func room(cap: CGFloat, fixed: [CGFloat] = Self.fixed, withMeta: Bool) -> CGFloat {
        cap - fixed.reduce(0, +) - gaps(fixed.count + 1 + (withMeta ? 1 : 0))
    }

    private func solve(title: CGFloat, meta: CGFloat?, cap: CGFloat, fixed: [CGFloat] = Self.fixed,
                       badgeIndex: Int? = nil) -> Layout.Solution {
        Layout.solve(titleIdeal: title, metaIdeal: meta, fixed: fixed, cap: cap, badgeIndex: badgeIndex)
    }

    // MARK: - Everything fits

    @Test(arguments: caps)
    func givenAShortTitleAndShortMeta_whenTheyFit_thenEveryPartTakesItsIdealWidth(cap: CGFloat) {
        // given
        let metaIdeal: CGFloat = 100

        // when
        let solution = solve(title: Self.short, meta: metaIdeal, cap: cap)

        // then
        #expect(solution == Layout.Solution(titleWidth: Self.short, metaWidth: metaIdeal, metaDropped: false, badgeWidth: nil))
    }

    @Test(arguments: caps)
    func givenAShortTitleWithMeta_whenCapsDiffer_thenTheTitleKeepsItsFullIdealWidthUnderEachCap(cap: CGFloat) {
        // given / when
        let solution = solve(title: Self.short, meta: Self.metaIdeal, cap: cap)

        // then meta may give way, the short title does not
        #expect(solution.titleWidth == Self.short)
        #expect(solution.metaWidth != nil)
        #expect(!solution.metaDropped)
    }

    @Test(arguments: caps)
    func givenAShortTitleWithoutMeta_whenSolved_thenTheTitleIsAtItsIdealWidth(cap: CGFloat) {
        // given / when
        let solution = solve(title: Self.short, meta: nil, cap: cap)

        // then
        #expect(solution == Layout.Solution(titleWidth: Self.short, metaWidth: nil, metaDropped: false, badgeWidth: nil))
    }

    @Test func givenPartsThatSumExactlyToTheCap_whenSolved_thenNothingTruncates() {
        // given
        let cap = Self.fixed.reduce(0, +) + gaps(5) + Self.medium + Self.metaIdeal

        // when
        let solution = solve(title: Self.medium, meta: Self.metaIdeal, cap: cap)

        // then
        #expect(solution == Layout.Solution(titleWidth: Self.medium, metaWidth: Self.metaIdeal, metaDropped: false, badgeWidth: nil))
    }

    // MARK: - Title truncates first

    @Test(arguments: caps)
    func givenALongTitleWithMeta_whenSolved_thenTheTitleTruncatesAndMetaKeepsAtLeastItsShare(cap: CGFloat) {
        // given
        let available = room(cap: cap, withMeta: true)

        // when
        let solution = solve(title: Self.long, meta: Self.metaIdeal, cap: cap)

        // then
        let meta = solution.metaWidth ?? 0
        #expect(solution.titleWidth < Self.long)
        #expect(solution.titleWidth >= Layout.titleFloor)
        #expect(meta >= min(Self.metaIdeal, Layout.metaShare * available) - 0.001)
        #expect(!solution.metaDropped)
        #expect(solution.titleWidth + meta <= available + 0.001)
    }

    @Test(arguments: caps)
    func givenAFortyOneCharacterTitle_whenSolved_thenTheTitleNeverFallsBelowEightyWhileMetaShows(cap: CGFloat) {
        // given / when
        let solution = solve(title: Self.medium, meta: Self.metaIdeal, cap: cap)

        // then
        #expect(solution.metaWidth != nil)
        #expect(solution.titleWidth >= 80)
        #expect((solution.metaWidth ?? 0) >= Layout.metaFloor)
    }

    @Test func givenTheWidestCap_whenAFortyOneCharacterTitleHasRoomForMetaToo_thenOnlyTheTitleGivesWay() {
        // given the 560 point cap: 398 points shared between a 287 point title and 150 point meta
        let solution = solve(title: Self.medium, meta: Self.metaIdeal, cap: 560)

        // then
        #expect(solution.metaWidth == Self.metaIdeal)
        #expect(solution.titleWidth < Self.medium)
        #expect(abs(solution.titleWidth - (room(cap: 560, withMeta: true) - Self.metaIdeal)) < 0.001)
    }

    @Test(arguments: caps)
    func givenALongTitleWithoutMeta_whenSolved_thenTheTitleFillsTheRoomExactly(cap: CGFloat) {
        // given / when
        let solution = solve(title: Self.long, meta: nil, cap: cap)

        // then
        #expect(abs(solution.titleWidth - room(cap: cap, withMeta: false)) < 0.001)
        #expect(solution.metaWidth == nil)
        #expect(!solution.metaDropped)
    }

    // MARK: - Meta boundary

    /// A cap whose room for title and meta together is exactly `room`, with one fixed part of 100.
    private func cap(forRoom room: CGFloat) -> CGFloat { 100 + gaps(3) + room }

    @Test func givenRoomThatLeavesMetaExactlyItsFloor_whenSolved_thenMetaIsKeptAtTheFloorWithTheTitleAtEighty() {
        // given 80 for the title plus the 60 floor
        let solution = solve(title: 500, meta: Self.metaIdeal, cap: cap(forRoom: 140), fixed: [100])

        // then
        #expect(solution.metaWidth == Layout.metaFloor)
        #expect(solution.titleWidth == Layout.titleFloor)
        #expect(!solution.metaDropped)
    }

    @Test func givenRoomThatLeavesMetaJustUnderItsFloor_whenSolved_thenMetaIsDroppedAndTheTitleReclaimsItsRoom() {
        // given
        let cap = cap(forRoom: 139)

        // when
        let solution = solve(title: 500, meta: Self.metaIdeal, cap: cap, fixed: [100])

        // then
        #expect(solution.metaWidth == nil)
        #expect(solution.metaDropped)
        #expect(solution.titleWidth >= Layout.titleFloor)
        #expect(abs(solution.titleWidth - (cap - 100 - gaps(2))) < 0.001)
    }

    @Test func givenCrowdedFixedParts_whenSolved_thenMetaIsDroppedAndTheTitleStaysAtLeastEighty() {
        // given a wide badge that leaves 88 points for title and meta
        let solution = solve(title: 300, meta: Self.metaIdeal, cap: 360, fixed: [200, 16, 24])

        // then
        #expect(solution.metaDropped)
        #expect(solution.metaWidth == nil)
        #expect(solution.titleWidth >= Layout.titleFloor)
    }

    @Test func givenNoMetaAndNoRoom_whenSolved_thenTheTitleTakesWhatIsLeftSoTheTotalStaysInTheCap() {
        // given the fixed parts alone exceed the cap
        let solution = solve(title: 500, meta: nil, cap: 100, fixed: [90, 16, 24])

        // then the last resort: the title goes below its floor rather than overflowing further
        #expect(solution.titleWidth == 0)
        #expect(!solution.metaDropped)
    }

    @Test func givenATitleShorterThanTheFloor_whenSolvedUnderPressure_thenItIsNeverInflatedBeyondItsIdeal() {
        // given a 40 point title and 100 points of room
        let solution = solve(title: 40, meta: Self.metaIdeal, cap: cap(forRoom: 100), fixed: [100])

        // then
        #expect(solution.titleWidth == 40)
        #expect(solution.metaWidth == 60)
    }

    @Test(arguments: caps)
    func givenAMetaNarrowerThanItsFloor_whenItFitsWithTheTitle_thenItKeepsItsIdealWidth(cap: CGFloat) {
        // given a one word meta that fits at its own width
        let solution = solve(title: Self.short, meta: 33, cap: cap)

        // then the floor only applies to meta that had to be squeezed
        #expect(solution == Layout.Solution(titleWidth: Self.short, metaWidth: 33, metaDropped: false, badgeWidth: nil))
    }

    @Test(arguments: caps)
    func givenAShortMetaAndALongTitle_whenSolved_thenTheShortMetaStaysAtItsIdealWidth(cap: CGFloat) {
        // given a one word meta under 60 points and a title that must truncate
        let solution = solve(title: Self.long, meta: 33, cap: cap)

        // then it is allotted its full ideal width, so it is not dropped
        #expect(solution.metaWidth == 33)
        #expect(!solution.metaDropped)
        #expect(solution.titleWidth >= Layout.titleFloor)
    }

    @Test func givenAMetaShorterThanItsShare_whenSolved_thenItKeepsItsIdealWidth() {
        // given a 70 point meta and a long title
        let solution = solve(title: Self.long, meta: 70, cap: 360)

        // then
        #expect(solution.metaWidth == 70)
        #expect(!solution.metaDropped)
    }

    // MARK: - Properties across the whole range

    @Test func givenAnySizesAndCaps_whenSolved_thenTheInvariantsHold() {
        // given
        let titles: [CGFloat] = [0, 20, 40, 63, 80, 120, 287, 500, 840]
        let metas: [CGFloat?] = [nil, 33, 60, 100, 150, 400]
        let fixedSets: [[CGFloat]] = [[], [60], [90, 16, 24], [200, 16, 24], [300, 16, 24]]
        let caps: [CGFloat] = [120, 240, 360, 440, 560]

        for title in titles {
            for meta in metas {
                for fixed in fixedSets {
                    for cap in caps {
                        // when
                        let badgeIndex: Int? = fixed.count >= 3 ? 0 : nil
                        let solution = Layout.solve(titleIdeal: title, metaIdeal: meta, fixed: fixed, cap: cap, badgeIndex: badgeIndex)
                        let context = "title \(title) meta \(String(describing: meta)) fixed \(fixed) cap \(cap)"

                        // then the title never grows past its ideal
                        #expect(solution.titleWidth <= title + 0.001, "\(context)")
                        // meta, when drawn, is never wider than ideal and is under 60 only at its own ideal width
                        if let drawn = solution.metaWidth {
                            #expect(drawn <= (meta ?? 0) + 0.001, "\(context)")
                            #expect(drawn >= Layout.metaFloor - 0.001 || abs(drawn - (meta ?? 0)) < 0.001, "\(context)")
                            #expect(!solution.metaDropped, "\(context)")
                        }
                        if meta == nil { #expect(!solution.metaDropped && solution.metaWidth == nil, "\(context)") }
                        // the title keeps its floor while meta shows
                        if solution.metaWidth != nil { #expect(solution.titleWidth >= min(title, Layout.titleFloor) - 0.001, "\(context)") }
                        // the total never exceeds the cap unless the parts that cannot shrink already do
                        let badgeIdeal = badgeIndex.map { fixed[$0] } ?? 0
                        let others = fixed.reduce(0, +) - badgeIdeal
                        let badge = solution.badgeWidth ?? badgeIdeal
                        let parts = fixed.count + 1 + (solution.metaWidth == nil ? 0 : 1)
                        let total = others + badge + solution.titleWidth + (solution.metaWidth ?? 0) + gaps(parts)
                        let incompressible = others + gaps(fixed.count + 1)
                        if incompressible <= cap, badgeIndex != nil || solution.titleWidth >= Layout.titleFloor {
                            #expect(total <= cap + 0.001, "\(context) total \(total)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Badge minimum

    @Test func givenABadgeMinimum_whenOverBudget_thenTheBadgeNeverTruncatesBelowIt() {
        // given a 300 point badge with a 120 point minimum and no room for the title floor
        let solution = Layout.solve(titleIdeal: 300, metaIdeal: nil, fixed: [300, 16, 24], cap: 200, badgeIndex: 0, badgeMinimum: 120)

        // then
        #expect(solution.badgeWidth == 120)
        #expect(solution.titleWidth >= 0)
    }

    @Test func givenABadgeMinimumAboveTheBadgesIdeal_whenOverBudget_thenTheBadgeKeepsItsIdeal() {
        // given
        let solution = Layout.solve(titleIdeal: 300, metaIdeal: nil, fixed: [100, 16, 24], cap: 120, badgeIndex: 0, badgeMinimum: 400)

        // then
        #expect(solution.badgeWidth == nil)
    }

    @Test func givenABadgeMinimumBelowTheTruncatedWidth_whenOverBudget_thenTheTruncatedWidthWins() {
        // given
        let solution = solve(title: 300, meta: Self.metaIdeal, cap: 360, fixed: [300, 16, 24], badgeIndex: 0)
        let bounded = Layout.solve(titleIdeal: 300, metaIdeal: Self.metaIdeal, fixed: [300, 16, 24], cap: 360, badgeIndex: 0, badgeMinimum: 50)

        // then
        #expect(bounded == solution)
    }

    // MARK: - Over budget

    @Test func givenFixedPartsThatLeaveLessThanTheTitleFloor_whenSolved_thenMetaIsDroppedAndTheBadgeTruncates() {
        // given a 300 point badge beside a busy slot and status in a 360 cap
        let solution = solve(title: 300, meta: Self.metaIdeal, cap: 360, fixed: [300, 16, 24], badgeIndex: 0)

        // then the badge gives way down to cap - others - gaps - 80 and the title keeps its floor
        let expectedBadge = 360 - 40 - gaps(4) - 80
        #expect(solution.metaDropped)
        #expect(solution.metaWidth == nil)
        #expect(solution.badgeWidth.map { abs($0 - expectedBadge) < 0.001 } == true)
        #expect(solution.titleWidth == Layout.titleFloor)
    }

    @Test func givenABadgeThatFitsOnceMetaIsDropped_whenSolved_thenItKeepsItsIdealWidth() {
        // given
        let solution = solve(title: 300, meta: Self.metaIdeal, cap: 360, fixed: [200, 16, 24], badgeIndex: 0)

        // then
        #expect(solution.badgeWidth == nil)
        #expect(solution.titleWidth >= Layout.titleFloor)
    }

    @Test func givenNonBadgePartsAloneOverTheCap_whenSolved_thenTheBadgeVanishesAndTheTitleTakesWhatIsLeft() {
        // given
        let solution = solve(title: 300, meta: nil, cap: 100, fixed: [300, 60, 60], badgeIndex: 0)

        // then
        #expect(solution.badgeWidth == 0)
        #expect(solution.titleWidth >= 0)
        #expect(solution.titleWidth <= 300)
    }

    @Test(arguments: caps)
    func givenOverBudgetParts_whenSolved_thenTheTotalNeverExceedsTheCap(cap: CGFloat) {
        // given
        let fixed: [CGFloat] = [cap, 16, 24]

        // when
        let solution = solve(title: 500, meta: Self.metaIdeal, cap: cap, fixed: fixed, badgeIndex: 0)

        // then
        let total = (solution.badgeWidth ?? fixed[0]) + 40 + solution.titleWidth + gaps(4)
        #expect(total <= cap + 0.001)
        #expect(solution.metaWidth == nil)
    }

    @Test func givenAShrinkingCap_whenSolved_thenMetaShrinksBeforeItDropsAndNeverReturnsAsASliver() {
        // given
        var previous: CGFloat? = .infinity
        var dropped = false

        // when
        for cap in stride(from: CGFloat(600), through: 150, by: -5) {
            let solution = solve(title: Self.long, meta: Self.metaIdeal, cap: cap)
            if let width = solution.metaWidth {
                // then meta never grows again as the cap shrinks, and never sits under 60
                #expect(!dropped, "meta came back at cap \(cap)")
                #expect(width <= (previous ?? 0) + 0.001, "cap \(cap)")
                #expect(width >= Layout.metaFloor)
                previous = width
            } else {
                dropped = true
                previous = nil
            }
        }

        // then it did drop eventually
        #expect(dropped)
    }

    // MARK: - Hosted layout without a window

    private func fittingWidth(cap: CGFloat, title: CGFloat, meta: CGFloat?) -> CGFloat {
        let view = Layout(cap: cap) {
            Color.clear.frame(width: title, height: 20).topBarRole(.title)
            Color.clear.frame(width: Self.fixed[0], height: 20).topBarRole(.badge)
            Color.clear.frame(width: Self.fixed[1], height: 20).topBarRole(.busy)
            if let meta { Color.clear.frame(width: meta, height: 16).topBarRole(.meta) }
            Color.clear.frame(width: Self.fixed[2], height: 20).topBarRole(.status)
        }
        return NSHostingView(rootView: view).fittingSize.width
    }

    @MainActor
    @Test(arguments: caps)
    func givenSubviewsWithIdealSizes_whenTheLayoutMeasures_thenItFitsTheCapAndMatchesTheSolver(cap: CGFloat) {
        // given
        let solution = solve(title: Self.long, meta: Self.metaIdeal, cap: cap)
        let expected = Self.fixed.reduce(0, +) + solution.titleWidth + (solution.metaWidth ?? 0)
            + gaps(Self.fixed.count + 1 + (solution.metaWidth == nil ? 0 : 1))

        // when
        let width = fittingWidth(cap: cap, title: Self.long, meta: Self.metaIdeal)

        // then
        #expect(width <= cap + 0.5)
        #expect(abs(width - expected) < 0.5)
    }

    @MainActor
    @Test func givenAShortTitleAndMeta_whenTheLayoutMeasuresUnderTheWidestCap_thenItIsTheSumOfTheIdealWidths() {
        // given
        let expected = Self.fixed.reduce(0, +) + Self.short + 100 + gaps(5)

        // when
        let width = fittingWidth(cap: 560, title: Self.short, meta: 100)

        // then
        #expect(abs(width - expected) < 0.5)
    }
}
