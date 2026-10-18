import Foundation
@testable import PbUI
import SwiftUI
import Testing

// `MarkdownText` is a `View`, so Swift 6 infers `@MainActor` isolation for its static members too.
@MainActor
@Suite struct MarkdownTextTableTests {

    @Test func givenAPipeTableWithASeparator_whenParsingBlocks_thenProducesOneTableWithoutTheSeparator() {
        // given
        let text = "| File | Change |\n|---|:---:|\n| `A.swift` | 12 → 16 |\n| B.swift | none |"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.table([["File", "Change"], ["`A.swift`", "12 → 16"], ["B.swift", "none"]])])
    }

    @Test func givenPipeLinesWithNoSeparatorRow_whenParsingBlocks_thenTheyFallBackToACodeBlock() {
        // given
        let text = "| not | a table |\n| still | prose |"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.code("| not | a table |\n| still | prose |")])
    }

    @Test func givenProseAroundATable_whenParsingBlocks_thenEachKeepsItsOwnBlock() {
        // given
        let text = "Before\n| H |\n|---|\n| v |\nAfter"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.paragraph("Before"), .table([["H"], ["v"]]), .paragraph("After")])
    }

    @Test func givenInlineCode_whenStyled_thenOnlyTheCodeRunGetsTheCodeFontAndTint() {
        // given
        let codeFont = Font.pb(.body, design: .monospaced)

        // when
        let styled = MarkdownText.inline("run `swift test` now", codeFont: codeFont)

        // then
        let codeRuns = styled.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(codeRuns.count == 1)
        #expect(codeRuns.allSatisfy { $0.font == codeFont && $0.backgroundColor == .codeFill })
        #expect(styled.runs.filter { $0.inlinePresentationIntent == nil }.allSatisfy { $0.font == nil && $0.backgroundColor == nil })
    }

    @Test func givenNumberedItems_whenParsingBlocks_thenEachKeepsItsMarker() {
        // given
        let text = "1. first\n2) second\n2024 is a year"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.numbered("1.", "first"), .numbered("2)", "second"), .paragraph("2024 is a year")])
    }

    @Test func givenARuleAndAQuote_whenParsingBlocks_thenTheyAreTheirOwnBlocks() {
        // given
        let text = "Above\n\n---\n> quoted text\nBelow"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.paragraph("Above"), .rule, .quote("quoted text"), .paragraph("Below")])
    }

    @Test func givenProseUnderlinedWithDashesOrEquals_whenParsingBlocks_thenItIsAHeadingNotARule() {
        // given
        let text = "Summary\n---\nBody\n\nTitle\n==="

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.heading("Summary"), .paragraph("Body"), .heading("Title")])
    }

    @Test func givenAnEscapedPipeInACell_whenParsingBlocks_thenItStaysInsideThatCell() {
        // given
        let text = "| Expression | Meaning |\n|---|---|\n| `a \\| b` | alternation |"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.table([["Expression", "Meaning"], ["`a | b`", "alternation"]])])
    }

    @Test func givenASeparatorWiderOrNarrowerThanTheHeader_whenParsingBlocks_thenTheLinesFallBackToACodeBlock() {
        // given
        let text = "| A | B |\n|---|\n| x | y |"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.code("| A | B |\n|---|\n| x | y |")])
    }

    @Test func givenRaggedBodyRows_whenParsingBlocks_thenTheyArePaddedOrCutToTheHeaderWidth() {
        // given
        let text = "| A | B |\n|---|---|\n| only |\n| x | y | extra |"

        // when
        let blocks = MarkdownText.blocks(text)

        // then
        #expect(blocks == [.table([["A", "B"], ["only", ""], ["x", "y"]])])
    }

    @Test func givenABareWebURL_whenStyledInline_thenItBecomesALink() {
        // given / when
        let styled = MarkdownText.inline("see https://example.com/docs for more")

        // then
        #expect(styled.runs.contains { $0.link == URL(string: "https://example.com/docs") })
    }

    @Test func givenAURLInsideInlineCode_whenStyledInline_thenItIsNotLinked() {
        // given / when
        let styled = MarkdownText.inline("run `curl https://example.com` now")

        // then
        #expect(styled.runs.allSatisfy { $0.link == nil })
    }
}
