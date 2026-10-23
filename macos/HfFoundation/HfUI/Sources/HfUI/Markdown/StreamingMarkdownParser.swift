import Foundation

// MARK: - StreamingMarkdownParser

/// Parses only the unresolved suffix. Completed source regions are retained by the state.
enum StreamingMarkdownParser {
    struct Result {
        var blocks: [StreamingMarkdownBlock] = []
        var sealedOffset: Int
        var sealedCount = 0
    }

    private struct Line {
        let raw: String
        let start: Int
        let end: Int
        let terminated: Bool
        var trimmed: String { raw.trimmingCharacters(in: .whitespaces) }
    }

    static func parse(_ text: String, offset: Int, isStreaming: Bool) -> Result {
        var parser = Parser(offset: offset, isStreaming: isStreaming)
        for line in lines(text, offset: offset) { parser.consume(line) }
        return parser.finish(text)
    }

    private struct Parser {
        var result: Result
        let isStreaming: Bool
        private var paragraph: [String] = []
        private var table: [String] = []
        private var code: [String]?
        private var blockStart: Int
        private var blockEnd: Int
        init(offset: Int, isStreaming: Bool) {
            self.result = Result(sealedOffset: offset)
            self.blockStart = offset
            self.blockEnd = offset
            self.isStreaming = isStreaming
        }

        private mutating func emit(_ block: MarkdownText.Block, start: Int, end: Int, sealed: Bool) {
            result.blocks.append(StreamingMarkdownBlock(id: start, block: block))
            if sealed {
                result.sealedOffset = end
                result.sealedCount = result.blocks.count
            }
        }

        private mutating func flush(_ sealed: Bool) {
            if !paragraph.isEmpty {
                emit(.paragraph(paragraph.joined(separator: "\n")), start: blockStart, end: blockEnd, sealed: sealed)
                paragraph = []
            }
            if !table.isEmpty {
                let header = MarkdownText.tableCells(table[0])
                if table.count >= 2, MarkdownText.isTableSeparator(table[1]), MarkdownText.tableCells(table[1]).count == header.count {
                    let body = table.dropFirst(2).map { line -> [String] in
                        let cells = MarkdownText.tableCells(line)
                        return (0 ..< header.count).map { $0 < cells.count ? cells[$0] : "" }
                    }
                    emit(.table([header] + body), start: blockStart, end: blockEnd, sealed: sealed)
                } else {
                    // A provisional header remains prose until its separator establishes a table.
                    let value = table.joined(separator: "\n")
                    emit(isStreaming && !sealed ? .paragraph(value) : .code(value), start: blockStart, end: blockEnd, sealed: sealed)
                }
                table = []
            }
        }

        mutating func consume(_ line: Line) {
            let value = line.trimmed
            if consumeFence(line) { return }
            if code != nil {
                code?.append(line.raw)
                blockEnd = line.end
                return
            }
            if value.isEmpty {
                consumeBlank(line)
                return
            }
            if consumeProvisionalLookahead(line) { return }
            if isPipeLine(value, terminated: line.terminated) {
                if !paragraph.isEmpty { flush(line.terminated) }
                if table.isEmpty { blockStart = line.start }
                table.append(value)
                blockEnd = line.end
                return
            }
            if !table.isEmpty { flush(true) }
            if !paragraph.isEmpty, MarkdownText.isSetextUnderline(value) {
                emit(.heading(paragraph.joined(separator: " ")), start: blockStart, end: line.end, sealed: line.terminated)
                paragraph = []
                return
            }
            consumeTextLine(line)
        }

        private mutating func consumeTextLine(_ line: Line) {
            let value = line.trimmed
            if let block = MarkdownText.lineBlock(value) {
                // An unterminated rule can still become inline prose when more text arrives.
                flush(line.terminated || !MarkdownText.isRule(value))
                emit(block, start: line.start, end: line.end, sealed: line.terminated)
            } else {
                if paragraph.isEmpty { blockStart = line.start }
                paragraph.append(value)
                blockEnd = line.end
            }
        }

        private mutating func consumeProvisionalLookahead(_ line: Line) -> Bool {
            guard isStreaming, !line.terminated, !paragraph.isEmpty else { return false }
            let value = line.trimmed
            guard value.hasPrefix("|") || MarkdownText.isRule(value) || MarkdownText.isSetextUnderline(value) else { return false }
            // Keep reversible lookahead inside the one open prose block until its line closes.
            paragraph.append(value)
            blockEnd = line.end
            return true
        }

        private mutating func consumeBlank(_ line: Line) {
            blockEnd = line.end
            let sealed = line.terminated
            flush(sealed)
            if sealed {
                result.sealedOffset = line.end
                result.sealedCount = result.blocks.count
            }
        }

        private mutating func consumeFence(_ line: Line) -> Bool {
            guard line.trimmed.hasPrefix("```") else { return false }
            if let codeLines = code {
                emit(.code(codeLines.joined(separator: "\n")), start: blockStart, end: line.end, sealed: line.terminated)
                code = nil
            } else {
                flush(true)
                blockStart = line.start
                code = []
            }
            blockEnd = line.end
            return true
        }

        mutating func finish(_ text: String) -> Result {
            if var codeLines = code {
                if text.hasSuffix("\n") { codeLines.append("") }
                emit(.code(codeLines.joined(separator: "\n")), start: blockStart, end: blockEnd, sealed: false)
            }
            flush(false)
            return result
        }

        private func isPipeLine(_ value: String, terminated: Bool) -> Bool {
            value.hasPrefix("|") && (value.hasSuffix("|") && value.count > 1 || isStreaming && !terminated)
        }
    }

    private static func lines(_ text: String, offset: Int) -> [Line] {
        let bytes = Array(text.utf8)
        var result: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 10 {
            let end = index > start && bytes[index - 1] == 13 ? index - 1 : index
            result.append(Line(raw: String(bytes: bytes[start ..< end], encoding: .utf8) ?? "",
                               start: offset + start, end: offset + index + 1, terminated: true))
            start = index + 1
        }
        if start < bytes.count {
            result.append(Line(raw: String(bytes: bytes[start...], encoding: .utf8) ?? "",
                               start: offset + start, end: offset + bytes.count, terminated: false))
        }
        return result
    }
}
