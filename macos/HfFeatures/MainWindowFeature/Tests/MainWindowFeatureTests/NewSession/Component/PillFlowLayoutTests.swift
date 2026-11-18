import CoreGraphics
@testable import MainWindowFeature
import Testing

@Suite struct PillFlowLayoutTests {

    @Test func givenItemsThatAllFit_whenPacked_thenTheyShareOneRow() {
        // given / when
        let rows = PillFlowLayout.rows(itemWidths: [50, 60, 70], maxWidth: 300, spacing: 6)

        // then
        #expect(rows == [[0, 1, 2]])
    }

    @Test func givenAnItemThatOverflows_whenPacked_thenItStartsANewRow() {
        // given / when — 100 + 6 + 100 + 6 + 100 = 312 > 300
        let rows = PillFlowLayout.rows(itemWidths: [100, 100, 100], maxWidth: 300, spacing: 6)

        // then
        #expect(rows == [[0, 1], [2]])
    }

    @Test func givenAnItemWiderThanTheLine_whenPacked_thenItSitsAloneOnItsRow() {
        // given / when
        let rows = PillFlowLayout.rows(itemWidths: [40, 400, 40], maxWidth: 300, spacing: 6)

        // then
        #expect(rows == [[0], [1], [2]])
    }

    @Test func givenAnItemWiderThanTheLineFirst_whenPacked_thenItIsStillPlacedOnTheFirstRow() {
        // given / when
        let rows = PillFlowLayout.rows(itemWidths: [400, 40], maxWidth: 300, spacing: 6)

        // then
        #expect(rows == [[0], [1]])
    }

    @Test func givenNoItems_whenPacked_thenThereAreNoRows() {
        // given / when
        let rows = PillFlowLayout.rows(itemWidths: [], maxWidth: 300, spacing: 6)

        // then
        #expect(rows.isEmpty)
    }

    @Test func givenTwoItemsThatFillTheLineExactly_whenPacked_thenTheyShareTheRow() {
        // given / when — 147 + 6 + 147 = 300
        let rows = PillFlowLayout.rows(itemWidths: [147, 147], maxWidth: 300, spacing: 6)

        // then
        #expect(rows == [[0, 1]])
    }

    @Test func givenTwoItemsOneUnitOverTheLine_whenPacked_thenTheSecondWraps() {
        // given / when
        let rows = PillFlowLayout.rows(itemWidths: [147, 148], maxWidth: 300, spacing: 6)

        // then
        #expect(rows == [[0], [1]])
    }
}
