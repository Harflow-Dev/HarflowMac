import MonitorCore
import SwiftUI

// MARK: - StatusIcon

/// A task's status as a small icon: spinner ring while running, check for done, x for failed and
/// timed out, minus for cancelled. The accessibility label is the status label.
public struct StatusIcon: View {
    public let status: TaskStatus
    /// `.increased` on a selected, emphasized List row (a solid accent highlight): the icon turns
    /// white there so it doesn't vanish into the highlight.
    @Environment(\.backgroundProminence) private var prominence

    public init(status: TaskStatus) {
        self.status = status
    }

    /// The SF Symbol for a terminal or unknown status; `nil` while running (a spinner is drawn).
    public nonisolated static func symbolName(for status: TaskStatus) -> String? {
        switch status {
        case .running: nil
        case .completed: "checkmark.circle.fill"
        case .failed, .timedOut: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        case .other: "circle.dashed"
        }
    }

    public var body: some View {
        Group {
            if let symbol = Self.symbolName(for: status) {
                Image(systemName: symbol)
                    .font(.pb(.body))
                    .foregroundStyle(prominence == .increased ? Color.white : StatusColor.of(status))
            } else {
                RunningSpinner(tint: prominence == .increased ? .white : nil)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

// MARK: - RunningSpinner

/// The running indicator: an accent arc turning on a faint track, about 14 pt, so a running task
/// reads at a glance (the system mini spinner rendered as a faint grey sparkle). With Reduce Motion
/// on, the arc holds still.
public struct RunningSpinner: View {
    public var size: CGFloat
    public var tint: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 14, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        let color = tint ?? Color.runningFG
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
        prominence == .increased ? .white.opacity(0.8) : .secondaryText
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
        HStack(spacing: 12) {
            StatusIcon(status: .running)
            StatusIcon(status: .completed)
            StatusIcon(status: .failed)
            StatusIcon(status: .timedOut)
            StatusIcon(status: .cancelled)
            StatusIcon(status: .other("queued"))
        }
        .padding()
        .background(Color.windowBG)
    }
}
#endif
