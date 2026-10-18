import Foundation
@testable import PbUI
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
}
