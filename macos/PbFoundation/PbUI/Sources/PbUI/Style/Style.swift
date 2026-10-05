import AppKit
import MonitorCore
import SwiftUI

// MARK: - PbTextStyle

/// The Monitor's shared type scale, at native Mac text sizes. Every label, row and pane picks one
/// of these styles through `Font.pb(_:weight:design:)` instead of hard-coding a point size, so the
/// app reads like a native Mac app and a future size change happens in one place.
public enum PbTextStyle: CaseIterable, Sendable {
    /// Smallest text: metadata lines, status labels, section headings.
    case caption
    /// Secondary text: connection lines, footnotes, monospaced details.
    case secondary
    /// Standard body text at the macOS body size.
    case body
    /// Long-form reading text: agent messages and results.
    case reading
    /// Emphasised text: section and row titles.
    case headline
    /// Page titles.
    case title
    /// Largest text: the summary hero.
    case hero

    /// The point size the style renders at.
    public var pointSize: CGFloat {
        switch self {
        case .caption: 11
        case .secondary: 12
        case .body: 13
        case .reading: 14
        case .headline: 15
        case .title: 18
        case .hero: 22
        }
    }
}

extension Font {
    /// A font from the Monitor's shared type scale, with an optional weight and design.
    public static func pb(_ style: PbTextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        // swiftlint:disable:next no_literal_font_size - the type scale's single point of literal sizes; every other call site goes through it.
        .system(size: style.pointSize, weight: weight, design: design)
    }
}

// MARK: - PbRadius

/// The Monitor's corner radii.
public enum PbRadius {
    /// Cards and bubbles.
    public static let card: CGFloat = 10
    /// List rows and selection highlights.
    public static let row: CGFloat = 8
    /// Buttons and fields.
    public static let button: CGFloat = 7
}

/// Display styling only. Every fact about a backend comes from polybridge; this just picks colours
/// and a letter, falling back to neutral for a backend the app has never heard of.
public enum BackendStyle {
    public static func letter(_ backend: String) -> String {
        switch backend {
        case "claude": "C"
        case "codex": "X"
        case "opencode": "O"
        case "vibe": "V"
        case "antigravity": "A"
        default: String(backend.prefix(1)).uppercased()
        }
    }

    public static func colors(_ backend: String) -> (Color, Color) {
        switch backend {
        case "claude": (Palette.claudeBG.color, Palette.claudeFG.color)
        case "codex": (Palette.codexBG.color, Palette.codexFG.color)
        case "opencode": (Palette.opencodeBG.color, Palette.opencodeFG.color)
        case "vibe": (Palette.vibeBG.color, Palette.vibeFG.color)
        case "antigravity": (Palette.antigravityBG.color, Palette.antigravityFG.color)
        default: (Palette.otherBackendBG.color, Palette.otherBackendFG.color)
        }
    }

    /// The backend's identity dot colour; a neutral one for a backend the app has never heard of.
    public static func dotColor(_ backend: String) -> Color {
        dotEntry(backend).color
    }

    /// The backend's name as shown to people: the raw name with its first letter capitalised.
    public static func displayName(_ backend: String) -> String {
        backend.prefix(1).uppercased() + backend.dropFirst()
    }

    static func dotEntry(_ backend: String) -> Palette.Entry {
        switch backend {
        case "claude": Palette.dotClaude
        case "codex": Palette.dotCodex
        case "opencode": Palette.dotOpencode
        case "vibe": Palette.dotVibe
        case "antigravity": Palette.dotAntigravity
        default: Palette.dotOther
        }
    }

    /// The product name shown under the backend name on the New session
    /// sheet; `nil` for a backend the app has never heard of, so its card shows the name only.
    public static func helpText(_ backend: String) -> String? {
        switch backend {
        case "claude": "Claude Code CLI"
        case "codex": "OpenAI Codex CLI"
        case "vibe": "Mistral Vibe CLI, using your configured model"
        case "opencode": "Opencode CLI"
        case "antigravity": "Google Antigravity CLI"
        default: nil
        }
    }

    /// Whether polybridge accepts a turn cap — mirrors each backend's `supports_turn_cap`
    /// (claude and vibe; codex, opencode, antigravity and unknown backends get no field at all).
    public nonisolated static func supportsTurnLimit(_ backend: String) -> Bool {
        backend == "claude" || backend == "vibe"
    }

    /// The reasoning-effort levels polybridge accepts for `backend` — antigravity refuses `xhigh`; the catalog carries no levels, so this is New Session's table.
    public static func effortLevels(_ backend: String) -> [String] {
        backend == "antigravity" ? ["low", "medium", "high"] : ["low", "medium", "high", "xhigh"]
    }

    /// The backends the New session sheet offers. Display list only; `run` validates the choice itself.
    public static let known = ["claude", "codex", "opencode", "vibe", "antigravity"]
}

public struct Chip: View {
    public let text: String
    // swiftlint:disable:next identifier_name - public API name; renaming would break Chip's external call sites.
    public var bg: Color = .neutralFill
    // swiftlint:disable:next identifier_name - public API name; renaming would break Chip's external call sites.
    public var fg: Color = .neutralText

    // swiftlint:disable:next identifier_name - public init labels are external API; renaming would break call sites.
    public init(text: String, bg: Color = .neutralFill, fg: Color = .neutralText) {
        self.text = text
        self.bg = bg
        self.fg = fg
    }

    public var body: some View {
        Text(text)
            .font(.pb(.secondary, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
    }
}

public struct FreedomBadge: View {
    public let freedom: String?

    public init(freedom: String?) {
        self.freedom = freedom
    }

    public var body: some View {
        if let freedom {
            switch freedom {
            case "write_in_repo": Chip(text: freedom, bg: .warningBG, fg: .warningFG)
            case "read_only": Chip(text: freedom, bg: .runningBG, fg: .runningFG)
            case "publish", "unrestricted": Chip(text: freedom, bg: .dangerBG, fg: .dangerFG)
            default: Chip(text: freedom)
            }
        }
    }
}

public enum Format {
    /// Resolved once: `Format.repo(_:)` used to rebuild this from `ProcessInfo`'s whole environment
    /// dictionary on every single call (Monitor piece 12 — measured at ~110 ms across 6 large tasks'
    /// worth of rows). `HOME` never changes for the life of the process, so reading it once is
    /// behaviour-identical and just skips the repeated environment rebuild.
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    public static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, min = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, min, sec) : String(format: "%02d:%02d", min, sec)
    }

    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    public static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    public static func offset(_ date: Date?, from start: Date?) -> String {
        guard let date, let start else { return "" }
        return clock(max(0, date.timeIntervalSince(start)))
    }

    public static func repo(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The repository's name: the last path component, ignoring trailing slashes ("/Users/me/Code/app" → "app").
    public static func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

public struct StatusPill: View {
    public let task: TaskInfo

    public init(task: TaskInfo) {
        self.task = task
    }

    public var body: some View {
        if task.status.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    RunningSpinner(size: 12)
                    Text("Running · \(Format.clock(task.elapsed(now: context.date)))").monospacedDigit()
                }
                .font(.pb(.secondary, weight: .medium))
                .foregroundStyle(Color.runningFG)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.runningBG))
            }
        } else {
            HStack(spacing: 4) {
                Text(task.status.label)
                if let elapsed = task.elapsed() { Text("· \(Format.clock(elapsed))").monospacedDigit() }
                if task.takenOver { Text("· taken over") }
            }
            .font(.pb(.secondary, weight: .medium))
            .foregroundStyle(StatusColor.of(task.status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StatusColor.of(task.status).opacity(0.1)))
        }
    }
}

public enum StatusColor {
    public static func of(_ status: TaskStatus) -> Color {
        switch status {
        case .running: .runningFG
        case .completed: .doneGreen
        case .failed, .timedOut: .failedRed
        case .cancelled: .cancelledGray
        case .other: .secondary
        }
    }
}

/// The outcome line's colour rule (`TaskDetailView.swift:178`, MS-ACTIONS-3): red only when the
/// message starts with "Refused" — several genuine refusal headlines (`unknown_task`, `closed`/
/// `settled`/`exited`, `not_live_input`, `owner_not_alive`) do not start with that word and render
/// in the normal, secondary colour. Characterized as-is; moved out of the app target so both
/// TaskDetail and any future screen apply the exact same rule.
public enum OutcomeColor {
    public static func of(_ message: String) -> Color {
        message.hasPrefix("Refused") ? .failedRed : .secondary
    }
}

public struct SectionLabel: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// Just enough Markdown for an agent's messages and summaries: headings, bullets, numbered items,
/// quotes, horizontal rules, fenced code, pipe tables, and inline emphasis/code/links via
/// `AttributedString`. Anything else renders as plain text.
public struct MarkdownText: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public enum Block: Hashable {
        case heading(String), bullet(String), code(String), paragraph(String)
        /// A pipe table: the header row first, then the body rows (the `|---|` separator dropped).
        case table([[String]])
        /// A numbered item: its marker as written ("1." / "2)") and its text.
        case numbered(String, String)
        case quote(String)
        case rule
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var tableLines: [String] = []
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            // Only a header row followed by a `|---|` separator is a table; other pipe lines are prose.
            // …and its separator must have exactly the header's column count, which fixes the width.
            let header = tableCells(tableLines[0])
            if tableLines.count >= 2, isTableSeparator(tableLines[1]), tableCells(tableLines[1]).count == header.count {
                let body = tableLines.dropFirst(2).map { row -> [String] in
                    let cells = tableCells(row)
                    return (0 ..< header.count).map { $0 < cells.count ? cells[$0] : "" }
                }
                blocks.append(.table([header] + body))
            } else {
                // A malformed table keeps its layout as a code block rather than raw pipes in prose.
                blocks.append(.code(tableLines.joined(separator: "\n")))
            }
            tableLines = []
        }
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            flushTable()
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|"), line.hasSuffix("|"), line.count > 1 {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                tableLines.append(line)
                continue
            }
            flushTable()
            // A `---`/`===` line right under prose underlines it as a heading (setext), not a rule.
            if !paragraph.isEmpty, isSetextUnderline(line) {
                blocks.append(.heading(paragraph.joined(separator: " ")))
                paragraph = []
                continue
            }
            if let block = lineBlock(line) {
                flush()
                blocks.append(block)
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// A line that is a block on its own (heading, rule, list item, quote), or nil for prose.
    static func lineBlock(_ line: String) -> Block? {
        if line.hasPrefix("#") { return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)) }
        if isRule(line) { return .rule }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
        if let (marker, rest) = numberedItem(line) { return .numbered(marker, rest) }
        if line.hasPrefix(">") { return .quote(line.dropFirst().trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func isSetextUnderline(_ line: String) -> Bool {
        guard let first = line.first, first == "-" || first == "=" else { return false }
        return line.allSatisfy { $0 == first }
    }

    static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// "1. text" / "12) text" → ("1.", "text").
    static func numberedItem(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else { return nil }
        return ("\(digits)\(delimiter)", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Splits a table row on unescaped pipes; `\|` stays a literal pipe in the cell, code spans
    /// included, as GFM tables specify.
    static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        cells = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    public static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        autolink(&result)
        return result
    }

    /// Links bare URLs (`https://…`) that the Markdown parser leaves as text — never inside a code
    /// span or an existing link.
    static func autolink(_ string: inout AttributedString) {
        let plain = String(string.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        for match in matches {
            guard let url = match.url, let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()),
                  let textRange = Range(match.range, in: plain),
                  let lower = AttributedString.Index(textRange.lowerBound, within: string),
                  let upper = AttributedString.Index(textRange.upperBound, within: string) else { continue }
            let range = lower ..< upper
            let blocked = string[range].runs.contains { run in
                run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
            }
            if !blocked { string[range].link = url }
        }
    }

    /// `inline(_:)` with inline `code` set in `codeFont` on the code-block tint, so it reads as code
    /// rather than as a stray font change mid-sentence.
    public static func inline(_ text: String, codeFont: Font) -> AttributedString {
        var result = inline(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = codeFont
            result[run.range].backgroundColor = .codeFill
        }
        return result
    }

    /// A block quote: a leading bar, secondary text.
    public static func quote(_ content: some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Color.secondaryText.opacity(0.4)).frame(width: 3)
            content.foregroundStyle(Color.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A pipe table as a grid: a semibold header row, then the body rows, with a hairline between rows.
    public static func table(_ rows: [[String]], codeFont: Font) -> some View {
        let columns = rows.first?.count ?? 0
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0 ..< columns, id: \.self) { column in
                        Text(inline(column < row.count ? row[column] : "", codeFont: codeFont))
                            .fontWeight(index == 0 ? .semibold : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
    }

    private static let codeFont = Font.pb(.secondary, design: .monospaced)

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let value): Text(Self.inline(value, codeFont: Self.codeFont)).font(.pb(.headline, weight: .semibold))
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(Self.inline(value, codeFont: Self.codeFont)) }
                case .code(let value):
                    Text(value)
                        .font(.pb(.secondary, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.codeFill))
                case .paragraph(let value): Text(Self.inline(value, codeFont: Self.codeFont))
                case .table(let rows): Self.table(rows, codeFont: Self.codeFont)
                case .numbered(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text(marker).monospacedDigit(); Text(Self.inline(value, codeFont: Self.codeFont)) }
                case .quote(let value): Self.quote(Text(Self.inline(value, codeFont: Self.codeFont)))
                case .rule: Divider()
                }
            }
        }
        .font(.pb(.body))
        .textSelection(.enabled)
    }
}

public struct Banner: View {
    public let icon: String
    public let title: String
    public let text: String
    public var tint: Color = .accentLink

    public init(icon: String, title: String, text: String, tint: Color = .accentLink) {
        self.icon = icon
        self.title = title
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty { Text(title).font(.pb(.body, weight: .semibold)) }
                Text(text).font(.pb(.body)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.2)))
    }
}

#if DEBUG
#Preview("Chip & FreedomBadge") {
    HStack {
        Chip(text: "example")
        FreedomBadge(freedom: "read_only")
        FreedomBadge(freedom: "write_in_repo")
        FreedomBadge(freedom: "unrestricted")
    }
    .padding()
}

#Preview("SectionLabel") {
    SectionLabel(text: "Details").padding()
}

#Preview("MarkdownText") {
    MarkdownText(text: "# Heading\nSome *emphasis* and `code`.\n- bullet one\n- bullet two\n```\nfenced code\n```")
        .padding()
        .frame(width: 320)
}

#Preview("Banner") {
    Banner(icon: "info.circle", title: "Heads up", text: "This runs polybridge-setup, which edits the client's own configuration.")
        .padding()
        .frame(width: 360)
}

#Preview("StatusPill") {
    let running = TaskInfo(.object([
        "task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"),
        "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-42)))
    ]))!
    let done = TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed")]))!
    return VStack(alignment: .leading, spacing: 8) {
        StatusPill(task: running)
        StatusPill(task: done)
    }
    .padding()
}
#endif
