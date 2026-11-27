@testable import HfUI
import Testing

@Suite struct MarkdownListNestingTests {
    @Test(arguments: [("", 0), ("  ", 2), ("\t", 4), (" \t", 4), ("\t  ", 6), ("  \t", 4), ("x  ", 0)])
    func givenSpacesTabsAndMixedIndentation_whenMeasuringColumns_thenTabsAdvanceToMultiplesOfFour(
        indent: String, expected: Int
    ) {
        // given / when
        let columns = MarkdownListNesting.indentColumns(indent)

        // then
        #expect(columns == expected)
    }

    @Test(arguments: [[0, 2, 4], [0, 3, 6], [0, 4, 8]])
    func givenTwoThreeAndFourSpaceConventions_whenEnteringItems_thenDepthsAreZeroOneTwo(columns: [Int]) {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depths = columns.map { nesting.enterItem(column: $0) }

        // then
        #expect(depths == [0, 1, 2])
    }

    @Test func givenSiblingAndDedentedItems_whenEnteringItems_thenDepthReturnsToTheMatchingParent() {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depths = [0, 2, 4, 2, 0].map { nesting.enterItem(column: $0) }

        // then
        #expect(depths == [0, 1, 2, 1, 0])
    }

    @Test func givenOneExtraSpace_whenEnteringItem_thenItIsASibling() {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depths = [0, 1].map { nesting.enterItem(column: $0) }

        // then
        #expect(depths == [0, 0])
    }

    @Test func givenOneSpaceItemAfterANestedItem_whenEnteringItems_thenTheStackIsPopped() {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depths = [0, 2, 1].map { nesting.enterItem(column: $0) }

        // then
        #expect(depths == [0, 1, 0])
    }

    @Test func givenOverIndentedItem_whenEnteringItem_thenItNestsOneLevel() {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depths = [0, 8].map { nesting.enterItem(column: $0) }

        // then
        #expect(depths == [0, 1])
    }

    @Test func givenItemsDeeperThanMaximum_whenEnteringItems_thenDepthClampsAndDedentStillResolves() {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depths = [0, 2, 4, 6, 8, 10, 6, 2].map { nesting.enterItem(column: $0) }

        // then
        #expect(depths == [0, 1, 2, 3, 3, 3, 3, 1])
    }

    @Test func givenIndentedItemWithoutParent_whenEnteringItem_thenDepthIsZero() {
        // given
        var nesting = MarkdownListNesting()

        // when
        let depth = nesting.enterItem(column: 6)

        // then
        #expect(depth == 0)
    }

    @Test func givenUnindentedProse_whenNoted_thenNestingResets() {
        // given
        var nesting = MarkdownListNesting()
        _ = nesting.enterItem(column: 0)
        _ = nesting.enterItem(column: 2)

        // when
        nesting.noteNonListLine(column: 0)

        // then
        #expect(nesting == MarkdownListNesting())
        #expect(nesting.enterItem(column: 2) == 0)
    }

    @Test func givenIndentedProse_whenNoted_thenNestingIsKept() {
        // given
        var nesting = MarkdownListNesting()
        _ = nesting.enterItem(column: 0)
        _ = nesting.enterItem(column: 2)

        // when
        nesting.noteNonListLine(column: 2)

        // then
        #expect(nesting.enterItem(column: 4) == 2)
    }

    @Test func givenEachDepth_whenAskingBulletGlyph_thenDiscCircleThenSquare() {
        // given / when
        let glyphs = (0 ... 4).map { MarkdownText.bulletGlyph(depth: $0) }

        // then
        #expect(glyphs == ["\u{2022}", "\u{25E6}", "\u{25AA}", "\u{25AA}", "\u{25AA}"])
    }

    @Test func givenTheListIndentToken_whenComparedWithTheDesignRule_thenItIsTwentyPoints() {
        // given / when / then
        #expect(HfRadius.Metrics.markdownListLevelIndent == 20)
    }
}
