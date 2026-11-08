//
//  UnifiedDiffLines.swift
//  MainWindowFeature
//
//  A hunk-aware classifier of unified diff text. Only the position in the patch decides what a line is, so content
//  lines that look like headers (`---`, `+++`) are still content inside a hunk.
//

import Foundation

// MARK: - UnifiedDiffLines

/// Splits a stored patch into display lines. Pure; holds no state.
enum UnifiedDiffLines {

    /// What a line is.
    enum Kind: Equatable, Sendable {
        /// `diff --git`, `index`, `---`, `+++`, mode and similar lines outside a hunk.
        case meta
        /// `@@ ... @@`, which starts a hunk.
        case hunk
        case added, removed, context
        /// `\ No newline at end of file`.
        case noNewline
    }

    /// One classified line. `text` omits the leading `+`, `-` or space for added, removed and context lines, and is
    /// the whole line for the others. A trailing carriage return is removed from `text` and recorded in `hadCarriageReturn`.
    /// It describes itself without its text.
    struct Line: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let kind: Kind
        let text: String
        var hadCarriageReturn = false

        var description: String { "UnifiedDiffLines.Line(\(kind))" }
        var debugDescription: String { description }
    }

    /// Classifies `text`. Lines split on LF at the byte level and are classified on their first Unicode scalar, never on
    /// a grapheme, so a CRLF pair or a leading combining mark cannot hide a prefix.
    /// - Outside a hunk every line is meta until an `@@` line starts one.
    /// - Inside a hunk the first scalar decides: `+` added, `-` removed, a space context, `\` the no-newline marker, `@`
    ///   the next hunk. This holds even for content such as `--- x` or `+++ x`.
    /// - Any other line inside a hunk (a `diff --git` line that begins the next section, as in a type change's two
    ///   patches) leaves the hunk and is meta, so its `---` and `+++` header lines are meta too.
    /// - A line that is empty inside a hunk is an empty context line.
    static func classify(_ text: String) -> [Line] {
        var pieces = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if let last = pieces.last, last.isEmpty { pieces.removeLast() }
        var inHunk = false
        var result: [Line] = []
        result.reserveCapacity(pieces.count)
        for piece in pieces {
            var line = String(Substring(piece))
            var hadCR = false
            if piece.last == UInt8(ascii: "\r") {
                hadCR = true
                line.unicodeScalars.removeLast()
            }
            let scalars = line.unicodeScalars
            if piece.starts(with: "@@".utf8) {
                inHunk = true
                result.append(Line(kind: .hunk, text: line, hadCarriageReturn: hadCR))
            } else if inHunk, let first = scalars.first {
                let rest = String(scalars.dropFirst())
                switch first {
                case "+": result.append(Line(kind: .added, text: rest, hadCarriageReturn: hadCR))
                case "-": result.append(Line(kind: .removed, text: rest, hadCarriageReturn: hadCR))
                case " ": result.append(Line(kind: .context, text: rest, hadCarriageReturn: hadCR))
                case "\\": result.append(Line(kind: .noNewline, text: line, hadCarriageReturn: hadCR))
                default:
                    inHunk = false
                    result.append(Line(kind: .meta, text: line, hadCarriageReturn: hadCR))
                }
            } else if inHunk {
                result.append(Line(kind: .context, text: "", hadCarriageReturn: hadCR))
            } else {
                result.append(Line(kind: .meta, text: line, hadCarriageReturn: hadCR))
            }
        }
        return result
    }
}
