import Foundation
@testable import HfUI
import Testing

// `MarkdownText` is a `View`, so Swift 6 infers `@MainActor` isolation for its static members too.
@MainActor
@Suite struct MarkdownTextBlockParsingTests {
    
    @Test func givenAHeadingLine_whenParsingBlocks_thenProducesAHeadingBlockWithHashesStripped() {
        // given
        let text = "# Summary"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [.heading("Summary")])
    }
    
    @Test func givenBulletLinesWithDashOrStar_whenParsingBlocks_thenProducesBulletBlocks() {
        // given
        let text = "- first\n* second"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [.bullet("first"), .bullet("second")])
    }
    
    @Test func givenAFencedCodeBlock_whenParsingBlocks_thenProducesACodeBlockWithoutFences() {
        // given
        let text = "```\nlet x = 1\nlet y = 2\n```"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [.code("let x = 1\nlet y = 2")])
    }
    
    @Test func givenConsecutiveNonEmptyLines_whenParsingBlocks_thenJoinsThemIntoOneParagraph() {
        // given
        let text = "line one\nline two"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [.paragraph("line one\nline two")])
    }
    
    @Test func givenABlankLineBetweenParagraphs_whenParsingBlocks_thenSplitsThemApart() {
        // given
        let text = "first\n\nsecond"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [.paragraph("first"), .paragraph("second")])
    }
    
    @Test func givenMixedContent_whenParsingBlocks_thenPreservesReadingOrder() {
        // given
        let text = "# Heading\nparagraph text\n- bullet\n```\ncode\n```"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [
            .heading("Heading"),
            .paragraph("paragraph text"),
            .bullet("bullet"),
            .code("code")
        ])
    }
    
    @Test func givenAnUnclosedFencedCodeBlock_whenParsingBlocks_thenStillEmitsTheCodeCollectedSoFar() {
        // given
        let text = "```\ndangling"
        
        // when
        let blocks = MarkdownText.blocks(text)
        
        // then
        #expect(blocks == [.code("dangling")])
    }
    
    @Test func givenEmptyText_whenParsingBlocks_thenReturnsNoBlocks() {
        // given / when
        let blocks = MarkdownText.blocks("")
        
        // then
        #expect(blocks.isEmpty)
    }

    // MARK: - Nested lists

    @Test func givenOwnerNestedExample_whenParsingBlocks_thenDepthsAreZeroOneTwo() {
        // given
        let text = "1. First item\n  - nested bullet one\n    - deeper bullet"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [
            .numbered("1.", "First item", depth: 0),
            .bullet("nested bullet one", depth: 1),
            .bullet("deeper bullet", depth: 2)
        ])
    }

    @Test func givenCRLFNestedExample_whenParsingBlocks_thenMatchesTheLFParse() {
        // given
        let source = "1. First item\n  - nested bullet one\n    - deeper bullet\n  - back\n- top"

        // when
        let crlf = MarkdownText.blocks(source.replacingOccurrences(of: "\n", with: "\r\n"))

        // then
        #expect(crlf == MarkdownText.blocks(source))
        #expect(crlf.count == 5)
    }

    @Test func givenMixedOrderedAndUnorderedNesting_whenParsingBlocks_thenKindsAndDepthsInterleave() {
        // given
        let text = "- a\n  1. b\n    - c"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.bullet("a", depth: 0), .numbered("1.", "b", depth: 1), .bullet("c", depth: 2)])
    }

    @Test func givenTabIndentedItems_whenParsingBlocks_thenTabsNestOneLevel() {
        // given
        let text = "- a\n\t- b\n\t\t- c"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.bullet("a", depth: 0), .bullet("b", depth: 1), .bullet("c", depth: 2)])
    }

    @Test func givenOneSpaceItemAfterNestedItem_whenParsingBlocks_thenItPopsTheStack() {
        // given
        let text = "- a\n  - b\n - c"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.bullet("a", depth: 0), .bullet("b", depth: 1), .bullet("c", depth: 0)])
    }

    @Test func givenIndentedFenceInsideItem_whenParsingBlocks_thenCodeIsUnchangedAndNextItemKeepsDepth() {
        // given
        let text = "- a\n  - b\n  ```\n  let x = 1\n  ```\n  - c"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [
            .bullet("a", depth: 0), .bullet("b", depth: 1), .code("  let x = 1"), .bullet("c", depth: 1)
        ])
    }

    @Test func givenContinuationLine_whenParsingBlocks_thenItStaysAParagraphAndNestingContinues() {
        // given
        let text = "- a\n  - b\n    continued\n    - c"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [
            .bullet("a", depth: 0), .bullet("b", depth: 1), .paragraph("continued"), .bullet("c", depth: 2)
        ])
    }

    @Test func givenParagraphBetweenLists_whenParsingBlocks_thenSecondListStartsAtDepthZero() {
        // given
        let text = "- a\n  - b\nplain\n  - c"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.bullet("a", depth: 0), .bullet("b", depth: 1), .paragraph("plain"), .bullet("c", depth: 0)])
    }

    @Test func givenIndentedItemWithoutParent_whenParsingBlocks_thenDepthIsZero() {
        // given / when
        let blocks = MarkdownText.blocks("  - x")

        // then
        #expect(blocks == [.bullet("x", depth: 0)])
    }

    @Test func givenBlankLinesBetweenNestedItems_whenParsingBlocks_thenNestingContinues() {
        // given
        let text = "1. a\n\n   - b"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.numbered("1.", "a", depth: 0), .bullet("b", depth: 1)])
    }
}
