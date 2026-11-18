@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskBuilderColumnSizingTests

@Suite struct TaskBuilderColumnSizingTests {
    private func resolve(_ total: CGFloat, natural: CGFloat, minimum: CGFloat, column: CGFloat) -> TaskBuilderColumnSizing {
        TaskBuilderColumnSizing.resolve(total: total, topNatural: natural, topMinimum: minimum, columnMinimum: column)
    }

    @Test func givenNaturalTopFits_whenResolved_thenTopTakesItsNaturalHeightAndColumnTheRest() {
        // given / when
        let sizing = resolve(433, natural: 130, minimum: 48, column: 296)
        // then
        #expect(sizing.top == 130)
        #expect(sizing.column == 303)
    }

    @Test func givenNaturalTopTooTall_whenResolved_thenTopClampsToLeaveTheColumnItsMinimum() {
        // given / when
        let sizing = resolve(433, natural: 300, minimum: 48, column: 296)
        // then
        #expect(sizing.top == 137)
        #expect(sizing.column == 296)
    }

    @Test func givenTallNaturalTopAndRoomToSpare_whenResolved_thenTopIsCappedAtHalfTheTotal() {
        // given / when
        let sizing = resolve(600, natural: 400, minimum: 48, column: 100)
        // then
        #expect(sizing.top == 300)
        #expect(sizing.column == 300)
    }

    @Test func givenAnyInputs_whenResolved_thenTopNeverFallsBelowItsMinimumAndColumnIsTheRemainder() {
        for total in stride(from: CGFloat(0), through: 900, by: 37) {
            for natural in stride(from: CGFloat(0), through: 700, by: 53) {
                // given / when
                let sizing = resolve(total, natural: natural, minimum: 48, column: 296)
                // then
                #expect(sizing.top >= 48)
                #expect(sizing.column == max(0, total - sizing.top))
                if total >= 96 { #expect(sizing.top <= max(48, total / 2)) }
            }
        }
    }

    @Test func givenMinimumsOverflow_whenResolved_thenTopKeepsItsMinimumAndColumnGetsTheRest() {
        // given / when
        let sizing = resolve(300, natural: 200, minimum: 90, column: 296)
        // then
        #expect(sizing.top == 90)
        #expect(sizing.column == 210)
    }

    @Test func givenTopMinimumAboveNatural_whenResolved_thenTopIsRaisedToItsMinimum() {
        #expect(resolve(433, natural: 20, minimum: 48, column: 296).top == 48)
    }

    @Test(arguments: [CGFloat(0), -5, .nan, .infinity])
    func givenZeroNegativeOrNonFiniteTotal_whenResolved_thenNothingIsNegativeOrNonFinite(total: CGFloat) {
        // given / when
        let sizing = resolve(total, natural: 130, minimum: 48, column: 296)
        // then
        #expect(sizing.top == 48)
        #expect(sizing.column == 0)
    }

    @Test(arguments: [CGFloat.nan, .infinity, -1])
    func givenNonFiniteTopOrColumnInputs_whenResolved_thenTheyCountAsZero(value: CGFloat) {
        // given / when
        let sizing = resolve(433, natural: value, minimum: value, column: value)
        // then
        #expect(sizing == TaskBuilderColumnSizing(top: 0, column: 433))
    }

    @Test func givenGrowingTotal_whenResolved_thenTopNeverShrinksAndPartsSumToTotalOnceMinimumsFit() {
        // given
        var previousTop: CGFloat = 0
        // when / then
        for total in stride(from: CGFloat(0), through: 900, by: 10) {
            let sizing = resolve(total, natural: 130, minimum: 48, column: 296)
            #expect(sizing.top >= previousTop)
            if total >= 48 { #expect(sizing.top + sizing.column == total) }
            previousTop = sizing.top
        }
    }
}
