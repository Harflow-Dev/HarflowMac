//
//  TaskChangesDiffText.swift
//  MainWindowFeature
//
//  A patch as one attributed string, built off the main actor from classified lines and drawn by a TextKit text view. The
//  string is immutable once built, so it crosses isolation boundaries. Each line is an ordinary text line: added, removed and
//  context lines carry their diff prefix (`+`, `-`, space) in the text itself, which is also how assistive technology and
//  copying tell them apart. Text is escaped for bidi, format and control characters before it is stored.
//

import AppKit

// MARK: - TaskChangesDiffText

/// The drawn text of a diff. Equality is the identity taken from the patch bytes when it was built, so comparing two
/// diffs never walks their lines. Never printed.
final class TaskChangesDiffText: @unchecked Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {

    /// The attribute that carries each paragraph's `kindCode`, read when the background is drawn.
    static let kindKey = NSAttributedString.Key("hfDiffLineKind")
    static let lineHeight = TaskScreenStyle.Diff.text.lineHeight
    static let verticalInset: CGFloat = 4

    let attributed: NSAttributedString
    let lineCount: Int
    let identity: Int

    /// The height all lines need.
    var contentHeight: CGFloat { CGFloat(lineCount) * Self.lineHeight + 2 * Self.verticalInset }

    var description: String { "TaskChangesDiffText(\(lineCount) lines)" }
    var debugDescription: String { description }

    static func == (lhs: TaskChangesDiffText, rhs: TaskChangesDiffText) -> Bool {
        lhs === rhs || (lhs.identity == rhs.identity && lhs.lineCount == rhs.lineCount)
    }

    private init(attributed: NSAttributedString, lineCount: Int, identity: Int) {
        self.attributed = attributed
        self.lineCount = lineCount
        self.identity = identity
    }

    // MARK: Kinds and colours

    static func kindCode(_ kind: UnifiedDiffLines.Kind) -> Int {
        switch kind {
        case .meta: 0
        case .hunk: 1
        case .added: 2
        case .removed: 3
        case .context: 4
        case .noNewline: 5
        }
    }

    /// A colour that follows the appearance it is drawn in.
    static func dynamic(_ token: TaskScreenStyle.Token) -> NSColor {
        let (light, dark) = (token.light, token.dark)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }

    /// The full-width fill behind each kind, `nil` for none.
    static let fills: [Int: NSColor] = [
        kindCode(.added): dynamic(TaskScreenStyle.Diff.addFill), kindCode(.removed): dynamic(TaskScreenStyle.Diff.deleteFill),
        kindCode(.hunk): dynamic(TaskScreenStyle.Diff.hunkFill), kindCode(.meta): dynamic(TaskScreenStyle.Diff.hunkFill)
    ]

    // MARK: Building

    /// Builds the attributed string of `lines`, or `nil` when the surrounding task was cancelled first.
    static func build(lines: [UnifiedDiffLines.Line], identity: Int) -> TaskChangesDiffText? {
        let font = NSFont.monospacedSystemFont(ofSize: TaskScreenStyle.Diff.text.size, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byClipping
        let primary = dynamic(TaskScreenStyle.Colors.text)
        let muted = dynamic(TaskScreenStyle.Diff.hunkColor)
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index % 512 == 0, Task.isCancelled { return nil }
            let prefix = switch line.kind {
            case .added: "+"
            case .removed: "-"
            case .context: " "
            default: ""
            }
            let isMuted = [.meta, .hunk, .noNewline].contains(line.kind)
            let text = prefix + TaskChangesDisplayText.diffSafe(line.text) + (index == lines.count - 1 ? "" : "\n")
            output.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: isMuted ? muted : primary, .paragraphStyle: paragraph, kindKey: kindCode(line.kind)
            ]))
        }
        return TaskChangesDiffText(attributed: (output.copy() as? NSAttributedString) ?? output, lineCount: lines.count, identity: identity)
    }
}
