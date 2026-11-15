import MonitorCore
import SwiftUI

// MARK: - StatusGlyph

/// What a task status draws: an SF Symbol, one of the design's path glyphs, or the running spinner.
public enum StatusGlyph: Equatable, Sendable {
    /// An SF Symbol, by name.
    case symbol(String)
    /// One of the design's path glyphs, drawn by `StatusGlyphView`.
    case shape(StatusGlyphShape.Kind)
    /// The running spinner.
    case spinner
}

// MARK: - StatusIcon

/// A task's status as a plain glyph in a square frame, no disc behind it (HarflowDesign `fe6428c`, `.hd-glyph`):
/// check for done, x for failed and timed out, a filled stop for cancelled, the raised hand for needs input and
/// needs attention, a spinner while running, the workflow glyph for a finished workflow run and the parallel glyph
/// for a parallel group (accent while running, success once it has finished). Pending keeps a circle and any other raw
/// status the dashed circle (no design state).
/// The accessibility label follows the design's labels; an increased-prominence row (a solid accent selection)
/// turns the icon white so it doesn't vanish into the highlight.
public struct StatusIcon: View {

    /// What the row the icon sits on represents. A workflow run and a parallel group draw their own glyphs for the
    /// states the design gives them; a task is the default.
    public enum Kind: Equatable, Sendable {
        /// A task row.
        case task
        /// A workflow run row.
        case workflowRun
        /// A parallel group row.
        case parallelGroup
    }

    /// The status drawn.
    public let status: TaskStatus
    /// What the row represents.
    public let kind: Kind
    /// The icon's square frame: the sidebar passes its 15 pt metric while every other consumer keeps the shared 16 pt
    /// default.
    private let size: CGFloat
    /// `.increased` on a selected, emphasized List row (a solid accent highlight): the icon turns
    /// white there so it doesn't vanish into the highlight.
    @Environment(\.backgroundProminence) private var prominence

    /// - Parameters:
    ///   - status: the task status to draw.
    ///   - kind: what the row represents; `.task` by default.
    ///   - size: the icon's square frame, 16 pt by default.
    public init(status: TaskStatus, kind: Kind = .task, size: CGFloat = HfRadius.Metrics.statusIconSize) {
        self.status = status
        self.kind = kind
        self.size = size
    }

    /// The normalised raw status (`needs_input` and `Needs Input` read the same), or `nil` for a known status.
    private nonisolated static func raw(_ status: TaskStatus) -> String? {
        if case let .other(label) = status { return label.lowercased().replacingOccurrences(of: "_", with: " ") }
        return nil
    }

    /// Whether `status` asks for the person: needs input or needs attention.
    public nonisolated static func needsYou(_ status: TaskStatus) -> Bool {
        guard let raw = raw(status) else { return false }
        return raw == "needs input" || raw == "needs attention"
    }

    /// The approved glyph for a status on a row of `kind`.
    public nonisolated static func glyph(for status: TaskStatus, kind: Kind = .task) -> StatusGlyph {
        switch status {
        case .running: kind == .parallelGroup ? .shape(.parallel) : .spinner
        case .completed:
            switch kind {
            case .workflowRun: .shape(.workflow)
            case .parallelGroup: .shape(.parallel)
            case .task: .symbol("checkmark")
            }
        case .failed, .timedOut: kind == .parallelGroup ? .shape(.parallel) : .symbol("xmark")
        case .cancelled: kind == .parallelGroup ? .shape(.parallel) : .symbol("stop.fill")
        case .other:
            switch raw(status) ?? "" {
            case "settling": .spinner
            case "pending", "queued": .symbol("circle")
            case "needs input", "needs attention": .shape(.hand)
            default: .symbol("circle.dashed")
            }
        }
    }

    /// The SF Symbol for a status drawn as a symbol on a task row; `nil` while running or settling (a spinner) and
    /// for the hand, which is a path glyph. Derived from `glyph(for:kind:)` so the two tables cannot drift.
    public nonisolated static func symbolName(for status: TaskStatus) -> String? {
        if case let .symbol(name) = glyph(for: status, kind: .task) { return name }
        return nil
    }

    /// The glyph's colour on an ordinary row. Every kind shares the status colours (a running group is `runningFG`, as
    /// the spinner is), except a finished parallel group: the design draws it in success whatever its members' outcomes.
    public nonisolated static func tint(for status: TaskStatus, kind: Kind = .task) -> Color {
        if kind == .parallelGroup, status.isTerminal { return StatusColor.of(.completed) }
        if needsYou(status) { return Color.warningFG }
        if let raw = raw(status), raw == "pending" || raw == "queued" { return Color.cancelledGray }
        return StatusColor.of(status)
    }

    /// The spoken label: the design's "Needs you" for needs input and needs attention, "Parallel group, running" for a
    /// running group, "Parallel group, done" for a finished one and "Done" for a finished workflow run; every other
    /// state keeps the status label.
    public nonisolated static func accessibilityLabel(for status: TaskStatus, kind: Kind = .task) -> String {
        if needsYou(status) { return "Needs you" }
        if kind == .parallelGroup, status.isRunning { return "Parallel group, running" }
        if kind == .parallelGroup, status.isTerminal { return "Parallel group, done" }
        if kind == .workflowRun, status == .completed { return "Done" }
        return status.label
    }

    public var body: some View {
        let color = prominence == .increased ? Color.onAccent : Self.tint(for: status, kind: kind)
        Group {
            switch Self.glyph(for: status, kind: kind) {
            case let .symbol(name):
                Image(systemName: name).font(.hf(.body)).foregroundStyle(color)
            case let .shape(shape):
                StatusGlyphView(shape, size: size).foregroundStyle(color)
            case .spinner:
                RunningSpinner(tint: prominence == .increased ? .onAccent : nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: status, kind: kind))
    }
}

// MARK: - StatusIndicatorView

/// A badge indicator (`StatusBadgePresentation.Indicator`) drawn at `size` in `tint`: a symbol, a design path glyph or
/// the running spinner. Shared by every surface that draws a presentation's indicator outside the status capsule.
public struct StatusIndicatorView: View {
    /// The indicator to draw.
    public let indicator: StatusBadgePresentation.Indicator
    /// The colour of the symbol, glyph or spinner.
    public let tint: Color
    /// The square frame of a glyph or spinner.
    public let size: CGFloat
    /// The symbol's font; `nil` keeps the inherited font.
    public let font: Font?

    public init(_ indicator: StatusBadgePresentation.Indicator, tint: Color, size: CGFloat = HfRadius.Metrics.statusIconSize, font: Font? = nil) {
        self.indicator = indicator
        self.tint = tint
        self.size = size
        self.font = font
    }

    public var body: some View {
        switch indicator {
        case .spinner:
            RunningSpinner(size: size, tint: tint)
        case let .symbol(name):
            if let font {
                Image(systemName: name).font(font).foregroundStyle(tint)
            } else {
                Image(systemName: name).foregroundStyle(tint)
            }
        case let .glyph(kind):
            StatusGlyphView(kind, size: size).foregroundStyle(tint)
        }
    }
}

// MARK: - RunningSpinner

/// The running indicator: an accent arc turning on a faint track, about 14 pt, so a running task
/// reads at a glance (the system mini spinner rendered as a faint grey sparkle). Under Reduce
/// Motion — the system setting or the presentation-only override — the arc holds still.
public struct RunningSpinner: View {
    public var size: CGFloat
    public var tint: Color?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride

    public init(size: CGFloat = HfRadius.Metrics.spinnerSize, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    public var body: some View {
        let color = tint ?? Color.runningFG
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: HfRadius.Metrics.spinnerStroke)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: HfRadius.Metrics.spinnerStroke, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
            }
        }
        .frame(width: size, height: size)
        // Often the only sign a step is still going (a pending tool row), so it speaks for itself.
        .accessibilityElement()
        .accessibilityLabel("Running")
    }
}

// MARK: - SelectionForeground

public extension Color {
    /// Secondary text that stays readable on a selected row: white-ish on the solid accent
    /// highlight (`backgroundProminence == .increased`), the palette's secondary text elsewhere.
    static func secondaryText(on prominence: BackgroundProminence) -> Color {
        prominence == .increased ? .onAccent.opacity(0.8) : .secondaryText
    }
}

#if DEBUG
#Preview("StatusIcon - light") {
    StatusIconsPreview().preferredColorScheme(.light)
}

#Preview("StatusIcon - dark") {
    StatusIconsPreview().preferredColorScheme(.dark)
}

private struct StatusIconsPreview: View {
    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing12) {
            StatusIcon(status: .running)
            StatusIcon(status: .completed)
            StatusIcon(status: .failed)
            StatusIcon(status: .timedOut)
            StatusIcon(status: .cancelled)
            StatusIcon(status: .other("queued"))
            StatusIcon(status: .other("needs_attention"))
            StatusIcon(status: .other("needs_input"))
            StatusIcon(status: .completed, kind: .workflowRun)
            StatusIcon(status: .running, kind: .parallelGroup)
            StatusIcon(status: .completed, kind: .parallelGroup)
            StatusIcon(status: .other("unknown"))
        }
        .padding()
        .background(Color.windowBG)
    }
}

#Preview("RunningSpinner - paused under Reduce Motion") {
    HStack(spacing: HfRadius.Metrics.spacing16) {
        RunningSpinner()
        RunningSpinner(size: HfRadius.Metrics.badgeGlyphSize, tint: Color.doneGreen)
    }
    .padding()
    .background(Color.windowBG)
    .environment(\.hfReduceMotionOverride, true)
}

/// The sidebar's 15 pt frame (§6.1) beside the shared 16 pt default — the glyph and semantics are
/// identical, only the frame shrinks.
#Preview("StatusIcon sidebar size - light") {
    StatusIconSidebarSizePreview().preferredColorScheme(.light)
}

#Preview("StatusIcon sidebar size - dark") {
    StatusIconSidebarSizePreview().preferredColorScheme(.dark)
}

private struct StatusIconSidebarSizePreview: View {
    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing12) {
            StatusIcon(status: .completed)
            StatusIcon(status: .completed, size: HfRadius.Metrics.sidebarStatusIconSize)
            StatusIcon(status: .running)
            StatusIcon(status: .running, size: HfRadius.Metrics.sidebarStatusIconSize)
        }
        .padding()
        .background(Color.sidebarBG)
    }
}
#endif
