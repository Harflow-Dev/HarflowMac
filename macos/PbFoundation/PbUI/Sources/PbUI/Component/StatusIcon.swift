import MonitorCore
import SwiftUI

// MARK: - StatusIcon

/// A task's status as a small icon: spinner ring while running, check for done, x for failed and
/// timed out, minus for cancelled. The accessibility label is the status label.
public struct StatusIcon: View {
    public let status: TaskStatus

    public init(status: TaskStatus) {
        self.status = status
    }

    /// The SF Symbol for a terminal or unknown status; `nil` while running (a spinner is drawn).
    nonisolated static func symbolName(for status: TaskStatus) -> String? {
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
                    .foregroundStyle(StatusColor.of(status))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
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
