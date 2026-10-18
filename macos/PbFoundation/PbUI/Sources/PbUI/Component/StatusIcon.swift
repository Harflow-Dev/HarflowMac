import MonitorCore
import SwiftUI

// MARK: - StatusIcon

/// A task's status as a small icon: spinner ring while running, check for done, x for failed and
/// timed out, a stop glyph for cancelled, a triangle for attention, a circle for pending. The
/// symbols share the `StatusBadge`'s semantics (SPEC §5.1) so a state reads the same everywhere;
/// the accessibility label is the status label. An increased-prominence row (a solid accent
/// selection) turns the icon white so it doesn't vanish into the highlight.
public struct StatusIcon: View {
    public let status: TaskStatus
    /// The icon's square frame — a presentation-only input; the sidebar passes its 15 pt metric
    /// (§6.1) while every other consumer keeps the shared 16 pt default. The glyph itself and the
    /// accessibility label never change with it.
    private let size: CGFloat
    /// `.increased` on a selected, emphasized List row (a solid accent highlight): the icon turns
    /// white there so it doesn't vanish into the highlight.
    @Environment(\.backgroundProminence) private var prominence

    /// - Parameters:
    ///   - status: the task status to draw.
    ///   - size: the icon's square frame, 16 pt by default.
    public init(status: TaskStatus, size: CGFloat = PbRadius.Metrics.statusIconSize) {
        self.status = status
        self.size = size
    }

    /// The SF Symbol for a terminal or unknown status; `nil` while running or settling (a spinner
    /// is drawn). Pending and queued draw a circle; every other raw status keeps the honest
    /// dashed-circle unknown treatment.
    public nonisolated static func symbolName(for status: TaskStatus) -> String? {
        switch status {
        case .running: nil
        case .completed: "checkmark.circle.fill"
        case .failed, .timedOut: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case let .other(label):
            switch label.lowercased().replacingOccurrences(of: "_", with: " ") {
            case "settling": nil
            case "pending", "queued": "circle"
            case "needs input", "needs attention": "exclamationmark.triangle.fill"
            default: "circle.dashed"
            }
        }
    }

    private var attentionStatus: Bool {
        if case let .other(label) = status {
            return ["needs input", "needs attention"].contains(label.lowercased().replacingOccurrences(of: "_", with: " "))
        }
        return false
    }

    private var pendingStatus: Bool {
        if case let .other(label) = status {
            return ["pending", "queued"].contains(label.lowercased().replacingOccurrences(of: "_", with: " "))
        }
        return false
    }

    private var iconColor: Color {
        if attentionStatus { return Color.warningFG }
        if pendingStatus { return Color.cancelledGray }
        return StatusColor.of(status)
    }

    public var body: some View {
        Group {
            if let symbol = Self.symbolName(for: status) {
                Image(systemName: symbol)
                    .font(.pb(.body))
                    .foregroundStyle(prominence == .increased ? Color.onAccent : iconColor)
            } else {
                RunningSpinner(tint: prominence == .increased ? .onAccent : nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
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
    @Environment(\.pbReduceMotionOverride) private var reduceMotionOverride

    public init(size: CGFloat = PbRadius.Metrics.spinnerSize, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    private var reduceMotion: Bool {
        PbMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    public var body: some View {
        let color = tint ?? Color.runningFG
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: PbRadius.Metrics.spinnerStroke)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: PbRadius.Metrics.spinnerStroke, lineCap: .round))
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
        HStack(spacing: PbRadius.Metrics.spacing12) {
            StatusIcon(status: .running)
            StatusIcon(status: .completed)
            StatusIcon(status: .failed)
            StatusIcon(status: .timedOut)
            StatusIcon(status: .cancelled)
            StatusIcon(status: .other("queued"))
            StatusIcon(status: .other("needs_attention"))
            StatusIcon(status: .other("unknown"))
        }
        .padding()
        .background(Color.windowBG)
    }
}

#Preview("RunningSpinner - paused under Reduce Motion") {
    HStack(spacing: PbRadius.Metrics.spacing16) {
        RunningSpinner()
        RunningSpinner(size: PbRadius.Metrics.badgeGlyphSize, tint: Color.doneGreen)
    }
    .padding()
    .background(Color.windowBG)
    .environment(\.pbReduceMotionOverride, true)
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
        HStack(spacing: PbRadius.Metrics.spacing12) {
            StatusIcon(status: .completed)
            StatusIcon(status: .completed, size: PbRadius.Metrics.sidebarStatusIconSize)
            StatusIcon(status: .running)
            StatusIcon(status: .running, size: PbRadius.Metrics.sidebarStatusIconSize)
        }
        .padding()
        .background(Color.sidebarBG)
    }
}
#endif
