import MonitorCore
import SwiftUI

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    static let hairline = Color(hex: 0xE6E5EA)
    static let accentLink = Color(hex: 0x0A63CE)
    static let selectedRow = Color(hex: 0xDAE4F3)
    static let doneGreen = Color(hex: 0x1B7F3B)
    static let failedRed = Color(hex: 0xC4312B)
    static let cancelledGray = Color(hex: 0x6E6E76)
    static let runningBG = Color(hex: 0xE7EFFA)
    static let runningFG = Color(hex: 0x0A55B0)
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
        case "claude": (Color(hex: 0xF6E3DA), Color(hex: 0xA64B28))
        case "codex": (Color(hex: 0xE4E4E8), Color(hex: 0x1D1D1F))
        case "opencode": (Color(hex: 0xDDF0EE), Color(hex: 0x0F6B64))
        case "vibe": (Color(hex: 0xF1E6FA), Color(hex: 0x6B2FA0))
        default: (Color(hex: 0xEEEEF0), Color(hex: 0x3A3A3C))
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
    public var bg: Color = .init(hex: 0xF2F2F5)
    // swiftlint:disable:next identifier_name - public API name; renaming would break Chip's external call sites.
    public var fg: Color = .init(hex: 0x3A3A3C)

    // swiftlint:disable:next identifier_name - public init labels are external API; renaming would break call sites.
    public init(text: String, bg: Color = Color(hex: 0xF2F2F5), fg: Color = Color(hex: 0x3A3A3C)) {
        self.text = text
        self.bg = bg
        self.fg = fg
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
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
            case "write_in_repo": Chip(text: freedom, bg: Color(hex: 0xFDF0DC), fg: Color(hex: 0x8A4B00))
            case "read_only": Chip(text: freedom, bg: Color(hex: 0xE7EFFA), fg: Color(hex: 0x0A55B0))
            case "publish", "unrestricted": Chip(text: freedom, bg: Color(hex: 0xFBE4E2), fg: Color(hex: 0x9B2A23))
            default: Chip(text: freedom)
            }
        }
    }
}

public enum Format {
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
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

public struct StatusPill: View {
    public let task: TaskInfo
    public var drivenByUser = false

    public init(task: TaskInfo, drivenByUser: Bool = false) {
        self.task = task
        self.drivenByUser = drivenByUser
    }

    public var body: some View {
        if drivenByUser {
            Chip(text: "You're driving", bg: Color(hex: 0xFDF0DC), fg: Color(hex: 0x8A4B00))
        } else if task.status.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Running · \(Format.clock(task.elapsed(now: context.date)))").monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
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
            .font(.system(size: 11, weight: .medium))
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
            .font(.system(size: 10, weight: .semibold))
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
                case .heading(let value): Text(Self.inline(value)).font(.system(size: 13, weight: .semibold))
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(Self.inline(value)) }
                case .code(let value):
                    Text(value)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF5F5F7)))
                case .paragraph(let value): Text(Self.inline(value))
                }
            }
        }
        .font(.system(size: 13))
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
                if !title.isEmpty { Text(title).font(.system(size: 12, weight: .semibold)) }
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        StatusPill(task: done, drivenByUser: true)
    }
    .padding()
}
#endif
