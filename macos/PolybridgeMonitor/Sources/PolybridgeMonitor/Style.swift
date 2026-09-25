import MonitorCore
import SwiftUI

extension Color {
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
enum BackendStyle {
    static func letter(_ backend: String) -> String {
        switch backend {
        case "claude": return "C"
        case "codex": return "X"
        case "opencode": return "O"
        case "vibe": return "V"
        default: return String(backend.prefix(1)).uppercased()
        }
    }

    static func colors(_ backend: String) -> (Color, Color) {
        switch backend {
        case "claude": return (Color(hex: 0xF6E3DA), Color(hex: 0xA64B28))
        case "codex": return (Color(hex: 0xE4E4E8), Color(hex: 0x1D1D1F))
        case "opencode": return (Color(hex: 0xDDF0EE), Color(hex: 0x0F6B64))
        case "vibe": return (Color(hex: 0xF1E6FA), Color(hex: 0x6B2FA0))
        default: return (Color(hex: 0xEEEEF0), Color(hex: 0x3A3A3C))
        }
    }

    /// The backends the New session sheet offers. Display list only: polybridge-ctl has no
    /// command that lists backends, and `run` validates the choice itself.
    static let known = ["claude", "codex", "opencode", "vibe"]
}

struct BackendBadge: View {
    let backend: String
    var size: CGFloat = 20

    var body: some View {
        let (bg, fg) = BackendStyle.colors(backend)
        Text(BackendStyle.letter(backend))
            .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(fg)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(bg))
            .help(backend)
    }
}

struct Chip: View {
    let text: String
    var bg: Color = Color(hex: 0xF2F2F5)
    var fg: Color = Color(hex: 0x3A3A3C)

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
    }
}

struct FreedomBadge: View {
    let freedom: String?

    var body: some View {
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

enum Format {
    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func offset(_ date: Date?, from start: Date?) -> String {
        guard let date, let start else { return "" }
        return clock(max(0, date.timeIntervalSince(start)))
    }

    static func repo(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct StatusPill: View {
    let task: TaskInfo
    var drivenByUser = false

    var body: some View {
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
                .padding(.horizontal, 8).padding(.vertical, 3)
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
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(StatusColor.of(task.status).opacity(0.1)))
        }
    }
}

enum StatusColor {
    static func of(_ status: TaskStatus) -> Color {
        switch status {
        case .running: return .runningFG
        case .completed: return .doneGreen
        case .failed, .timedOut: return .failedRed
        case .cancelled: return .cancelledGray
        case .other: return .secondary
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

/// Just enough Markdown for an agent's final summary: headings, bullets, fenced code, and inline
/// emphasis/code/links via `AttributedString`. Anything else renders as plain text.
struct MarkdownText: View {
    let text: String

    enum Block: Hashable {
        case heading(String), bullet(String), code(String), paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
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

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let value): Text(Self.inline(value)).font(.system(size: 13, weight: .semibold))
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(Self.inline(value)) }
                case .code(let value):
                    Text(value).font(.system(size: 11, design: .monospaced))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF5F5F7)))
                case .paragraph(let value): Text(Self.inline(value))
                }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
    }
}

struct Banner: View {
    let icon: String
    let title: String
    let text: String
    var tint: Color = .accentLink

    var body: some View {
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
