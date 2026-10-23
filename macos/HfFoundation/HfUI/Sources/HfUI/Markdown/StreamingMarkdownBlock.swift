import Foundation

// MARK: - StreamingMarkdownBlock

/// A prepared Markdown block whose identity is its UTF-8 offset in the source.
public struct StreamingMarkdownBlock: Equatable, Identifiable, Sendable {
    /// The source offset stays unchanged when a provisional block changes its presentation kind.
    public let id: Int
    /// Inline Markdown has already been interpreted, without display fonts or colors.
    public let content: Content

    /// The supported block presentations.
    public enum Content: Equatable, Sendable {
        case heading(AttributedString)
        case bullet(AttributedString)
        case code(String)
        case paragraph(AttributedString)
        case table([[AttributedString]])
        case numbered(String, AttributedString)
        case quote(AttributedString)
        case rule
    }

    init(id: Int, block: MarkdownText.Block) {
        self.id = id
        switch block {
        case .heading(let text): self.content = .heading(MarkdownText.inline(text))
        case .bullet(let text): self.content = .bullet(MarkdownText.inline(text))
        case .code(let text): self.content = .code(text)
        case .paragraph(let text): self.content = .paragraph(MarkdownText.inline(text))
        case .table(let rows): self.content = .table(rows.map { $0.map { MarkdownText.inline($0) } })
        case .numbered(let marker, let text): self.content = .numbered(marker, MarkdownText.inline(text))
        case .quote(let text): self.content = .quote(MarkdownText.inline(text))
        case .rule: self.content = .rule
        }
    }
}
