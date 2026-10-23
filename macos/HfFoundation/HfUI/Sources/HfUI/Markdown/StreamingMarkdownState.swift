import Foundation

// MARK: - StreamingMarkdownState

/// Immutable incremental Markdown preparation, suitable for a detached presentation builder.
public struct StreamingMarkdownState: Equatable, Sendable {
    /// The complete source represented by this state.
    public private(set) var source = ""
    /// Prepared blocks, including the unresolved trailing block while streaming.
    public private(set) var blocks: [StreamingMarkdownBlock] = []
    /// Bytes interpreted by the most recent source change, excluding the retained sealed prefix.
    public private(set) var reparsedUTF8Count = 0

    private var sealedOffset = 0
    private var sealedCount = 0

    /// Creates an empty preparation state.
    public init() {}

    /// Reuses sealed blocks on append. Finalizing identical text preserves its exact presentation.
    public func updating(text: String, isStreaming: Bool) -> Self {
        guard !text.utf8.elementsEqual(source.utf8) else { return self }
        var result = self
        let preservesSealedPrefix = text.utf8.starts(with: source.utf8.prefix(sealedOffset))
        let offset = preservesSealedPrefix ? sealedOffset : 0
        let retained = preservesSealedPrefix ? Array(blocks.prefix(sealedCount)) : []
        let suffix = String(bytes: text.utf8.dropFirst(offset), encoding: .utf8) ?? ""
        let parsed = StreamingMarkdownParser.parse(suffix, offset: offset, isStreaming: isStreaming)
        result.source = text
        result.blocks = retained + parsed.blocks
        result.reparsedUTF8Count = suffix.utf8.count
        result.sealedOffset = parsed.sealedOffset
        result.sealedCount = retained.count + parsed.sealedCount
        return result
    }
}
