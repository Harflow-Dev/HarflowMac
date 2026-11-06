import HfUI
import SwiftUI

// MARK: - ComposerSendButtonStyle

/// The approved composer send control is a 32-point circle, including its disabled state.
struct ComposerSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: HfRadius.Metrics.segmentedHeight, height: HfRadius.Metrics.segmentedHeight)
            .foregroundStyle(isEnabled ? Color.onAccent : Color.tertiaryText)
            .background(Circle().fill(isEnabled ? Color.accentFill : Color.pillFill))
            .brightness(configuration.isPressed ? -0.04 : 0)
            .contentShape(Circle())
    }
}

#if DEBUG
#Preview("Composer send") {
    HStack {
        Button {} label: { Image(systemName: "arrow.up") }
            .buttonStyle(ComposerSendButtonStyle())
        Button {} label: { Image(systemName: "arrow.up") }
            .buttonStyle(ComposerSendButtonStyle())
.disabled(true)
    }
    .padding()
}
#endif
