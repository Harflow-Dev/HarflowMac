import Foundation
import SwiftUI

// MARK: - MarkdownText list depth

extension MarkdownText.Block {
    /// The block with its list depth set for a bullet or numbered item; any other block is unchanged.
    nonisolated func withListDepth(_ depth: Int) -> MarkdownText.Block {
        switch self {
        case .bullet(let text, _): .bullet(text, depth: depth)
        case .numbered(let marker, let text, _): .numbered(marker, text, depth: depth)
        default: self
        }
    }
}

extension MarkdownText {
    /// The bullet glyph for a list depth: disc, circle, then square for every deeper level.
    public nonisolated static func bulletGlyph(depth: Int) -> String {
        switch depth {
        case ..<1: "\u{2022}"
        case 1: "\u{25E6}"
        default: "\u{25AA}"
        }
    }

    /// The bullet glyph set in a slot as wide as the disc, so items at every depth start their text at the same
    /// offset from their indent; the square's own advance is wider. Hidden from VoiceOver.
    public static func bulletMarker(depth: Int) -> some View {
        Text(bulletGlyph(depth: 0))
            .hidden()
            .overlay(alignment: .leading) { Text(bulletGlyph(depth: depth)) }
            .accessibilityHidden(true)
    }

    /// `lineBlock(_:)` with list depth applied: a list item enters the nesting and carries its depth;
    /// any other non-blank line notes itself so unindented prose ends the list.
    nonisolated static func nestedLineBlock(_ line: String, column: Int, nesting: inout MarkdownListNesting) -> Block? {
        let block = lineBlock(line)
        switch block {
        case .bullet, .numbered: return block?.withListDepth(nesting.enterItem(column: column))
        default:
            nesting.noteNonListLine(column: column)
            return block
        }
    }

    /// Splits on `\n` scalars ("\r\n" is one `Character`) and drops one trailing `\r` per line, as the streaming parser does.
    nonisolated static func sourceLines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { slice in
            var line = String(String.UnicodeScalarView(slice))
            if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
            return line
        }
    }

    /// Only a header row followed by a `|---|` separator of the header's column count is a table;
    /// anything else keeps its layout as a code block rather than raw pipes in prose.
    nonisolated static func tableBlock(_ tableLines: [String]) -> Block {
        let header = tableCells(tableLines[0])
        guard tableLines.count >= 2, isTableSeparator(tableLines[1]), tableCells(tableLines[1]).count == header.count else {
            return .code(tableLines.joined(separator: "\n"))
        }
        let body = tableLines.dropFirst(2).map { row -> [String] in
            let cells = tableCells(row)
            return (0 ..< header.count).map { $0 < cells.count ? cells[$0] : "" }
        }
        return .table([header] + body)
    }
}
