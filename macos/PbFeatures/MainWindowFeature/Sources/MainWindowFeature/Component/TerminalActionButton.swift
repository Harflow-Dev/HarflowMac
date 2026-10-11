import PbUI
import SwiftUI

// MARK: - TerminalActionButton

/// An optional terminal handoff, visually distinct from the task's primary navigation action.
struct TerminalActionButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Label(title, systemImage: "terminal") }
            .buttonStyle(QuietButtonStyle(isFilled: false))
    }
}

#if DEBUG
private struct TerminalActionButtonPreview: View {
    var body: some View {
        HStack {
            Button("Open task") {}.buttonStyle(.link)
            Spacer()
            TerminalActionButton("Take over in terminal") {}
        }
        .padding()
        .frame(width: PbRadius.Metrics.toolRowPreviewWidth)
        .background(Color.windowBG)
    }
}

#Preview("TerminalActionButton - light") { TerminalActionButtonPreview().preferredColorScheme(.light) }
#Preview("TerminalActionButton - dark") { TerminalActionButtonPreview().preferredColorScheme(.dark) }
#endif
