import AppKit
import MonitorCore
import SwiftUI

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// An appearance-aware colour: `light` under Aqua, `dark` under Dark Aqua. A plain `Color(hex:)`
    /// is fixed, so it stays light while `.primary` text around it turns white in dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let hairline = Palette.hairline.color
    static let accentLink = Palette.accentLink.color
    static let selectedRow = Palette.selectedRow.color
    static let doneGreen = Palette.doneGreen.color
    static let failedRed = Palette.failedRed.color
    static let cancelledGray = Palette.cancelledGray.color
    static let runningBG = Palette.runningBG.color
    static let runningFG = Palette.runningFG.color
    /// Neutral card/chip fill (the install banner, a default `Chip`).
    static let neutralFill = Palette.neutralFill.color
    /// Text on `neutralFill`.
    static let neutralText = Palette.neutralText.color
    /// Caution foreground ("write_in_repo", "You're driving", the terminal marker).
    static let warningFG = Palette.warningFG.color
    static let warningBG = Palette.warningBG.color
    /// Danger foreground for the "publish"/"unrestricted" freedom chip.
    static let dangerFG = Palette.dangerFG.color
    static let dangerBG = Palette.dangerBG.color
    /// Fill behind monospaced blocks: fenced code, tool output, prompts.
    static let codeFill = Palette.codeFill.color
    static let editPreviewFill = Palette.editPreviewFill.color
    static let inspectorFill = Palette.inspectorFill.color
    static let diffHunkFill = Palette.diffHunkFill.color
    static let diffAddedFill = Palette.diffAddedFill.color
    static let diffRemovedFill = Palette.diffRemovedFill.color
}

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
    /// Emphasised text: section and row titles.
    case headline
    /// Largest text: page titles.
    case title

    /// The point size the style renders at.
    public var pointSize: CGFloat {
        switch self {
        case .caption: 11
        case .secondary: 12
        case .body: 13
        case .headline: 15
        case .title: 18
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

// MARK: - Palette

/// Every colour the Monitor defines, with its light and dark value. Light values are the app's
/// original ones; dark values keep the same role with readable contrast on a dark window.
enum Palette {
    struct Entry {
        let name: String
        let light: UInt32
        let dark: UInt32
        let color: Color

        init(_ name: String, light: UInt32, dark: UInt32) {
            self.name = name
            self.light = light
            self.dark = dark
            self.color = Color(light: light, dark: dark)
        }
    }

    static let hairline = Entry("hairline", light: 0xE6E5EA, dark: 0x3A3A3C)
    static let accentLink = Entry("accentLink", light: 0x0A63CE, dark: 0x5AA5FF)
    static let selectedRow = Entry("selectedRow", light: 0xDAE4F3, dark: 0x2A3A52)
    static let doneGreen = Entry("doneGreen", light: 0x1B7F3B, dark: 0x3FC06A)
    static let failedRed = Entry("failedRed", light: 0xC4312B, dark: 0xFF8A80)
    static let cancelledGray = Entry("cancelledGray", light: 0x6E6E76, dark: 0xA3A3AA)
    static let runningBG = Entry("runningBG", light: 0xE7EFFA, dark: 0x1C2D44)
    static let runningFG = Entry("runningFG", light: 0x0A55B0, dark: 0x6AAEFF)
    static let neutralFill = Entry("neutralFill", light: 0xF2F2F5, dark: 0x3A3A3C)
    static let neutralText = Entry("neutralText", light: 0x3A3A3C, dark: 0xD1D1D6)
    static let warningFG = Entry("warningFG", light: 0x8A4B00, dark: 0xF5B35A)
    static let warningBG = Entry("warningBG", light: 0xFDF0DC, dark: 0x4A3514)
    static let dangerFG = Entry("dangerFG", light: 0x9B2A23, dark: 0xFF8A80)
    static let dangerBG = Entry("dangerBG", light: 0xFBE4E2, dark: 0x4E2220)
    static let codeFill = Entry("codeFill", light: 0xF5F5F7, dark: 0x2C2C2E)
    static let editPreviewFill = Entry("editPreviewFill", light: 0xF8F8FA, dark: 0x262628)
    static let inspectorFill = Entry("inspectorFill", light: 0xFBFBFC, dark: 0x1E1E20)
    static let diffHunkFill = Entry("diffHunkFill", light: 0xF0F4FA, dark: 0x25303F)
    static let diffAddedFill = Entry("diffAddedFill", light: 0xE6F4EA, dark: 0x1F3A27)
    static let diffRemovedFill = Entry("diffRemovedFill", light: 0xFCE8E6, dark: 0x45211F)
    static let claudeBG = Entry("claudeBG", light: 0xF6E3DA, dark: 0x4A2A1E)
    static let claudeFG = Entry("claudeFG", light: 0xA64B28, dark: 0xF2A07E)
    static let codexBG = Entry("codexBG", light: 0xE4E4E8, dark: 0x48484C)
    static let codexFG = Entry("codexFG", light: 0x1D1D1F, dark: 0xE8E8ED)
    static let opencodeBG = Entry("opencodeBG", light: 0xDDF0EE, dark: 0x16403C)
    static let opencodeFG = Entry("opencodeFG", light: 0x0F6B64, dark: 0x5FD3C7)
    static let vibeBG = Entry("vibeBG", light: 0xF1E6FA, dark: 0x3A2650)
    static let vibeFG = Entry("vibeFG", light: 0x6B2FA0, dark: 0xC99BF0)
    static let otherBackendBG = Entry("otherBackendBG", light: 0xEEEEF0, dark: 0x3A3A3C)
    static let otherBackendFG = Entry("otherBackendFG", light: 0x3A3A3C, dark: 0xD1D1D6)

    static let all: [Entry] = [
        hairline, accentLink, selectedRow, doneGreen, failedRed, cancelledGray, runningBG, runningFG,
        neutralFill, neutralText, warningFG, warningBG, dangerFG, dangerBG, codeFill, editPreviewFill,
        inspectorFill, diffHunkFill, diffAddedFill, diffRemovedFill, claudeBG, claudeFG, codexBG, codexFG,
        opencodeBG, opencodeFG, vibeBG, vibeFG, otherBackendBG, otherBackendFG
    ]
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
        default: String(backend.prefix(1)).uppercased()
        }
    }

    public static func colors(_ backend: String) -> (Color, Color) {
        switch backend {
        case "claude": (Palette.claudeBG.color, Palette.claudeFG.color)
        case "codex": (Palette.codexBG.color, Palette.codexFG.color)
        case "opencode": (Palette.opencodeBG.color, Palette.opencodeFG.color)
        case "vibe": (Palette.vibeBG.color, Palette.vibeFG.color)
        default: (Palette.otherBackendBG.color, Palette.otherBackendFG.color)
        }
    }

    /// The backends the New session sheet offers. Display list only: polybridge-ctl has no
    /// command that lists backends, and `run` validates the choice itself.
    public static let known = ["claude", "codex", "opencode", "vibe"]
}

public struct BackendBadge: View {
    public let backend: String
    public var size: CGFloat = 20

    public init(backend: String, size: CGFloat = 20) {
        self.backend = backend
        self.size = size
    }

    public var body: some View {
        let (backgroundColor, foregroundColor) = BackendStyle.colors(backend)
        Text(BackendStyle.letter(backend))
            // swiftlint:disable:next no_literal_font_size - the badge letter scales with the badge frame (size * 0.55), not with the text scale.
            .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(foregroundColor)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(backgroundColor))
            .help(backend)
    }
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
                    ProgressView().controlSize(.mini)
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
        Text(text.uppercased())
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

/// Just enough Markdown for an agent's final summary: headings, bullets, fenced code, and inline
/// emphasis/code/links via `AttributedString`. Anything else renders as plain text.
public struct MarkdownText: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public enum Block: Hashable {
        case heading(String), bullet(String), code(String), paragraph(String)
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
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
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let value): Text(Self.inline(value)).font(.pb(.headline, weight: .semibold))
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(Self.inline(value)) }
                case .code(let value):
                    Text(value)
                        .font(.pb(.secondary, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.codeFill))
                case .paragraph(let value): Text(Self.inline(value))
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
#Preview("BackendBadge") {
    HStack { ForEach(BackendStyle.known, id: \.self) { BackendBadge(backend: $0) } }.padding()
}

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
