import SwiftUI

// MARK: - QuietButtonStyle

/// The design's toolbar button: a small neutral fill with a hairline border and button radius, in
/// the normal text colour — present, but not competing with the content. It draws its own
/// background, so a toolbar can neither strip it (a plain toolbar button is bezel-less until hover)
/// nor wrap it in a glass capsule.
public struct QuietButtonStyle: ButtonStyle {
    /// Shows the selected look — used for a toggle that is on (the inspector while it is open).
    public var isSelected: Bool
    /// `false` draws only the hairline outline (the inspector's full-width copy buttons); the fill
    /// still appears while pressed.
    public var isFilled: Bool

    public init(isSelected: Bool = false, isFilled: Bool = true) {
        self.isSelected = isSelected
        self.isFilled = isFilled
    }

    public func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, isSelected: isSelected, isFilled: isFilled)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let isFilled: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.pb(.body))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: PbRadius.button)
                    .fill(Color.pillFill.opacity(configuration.isPressed || isSelected ? 1 : (isFilled ? 0.75 : 0)))
            )
            .overlay(RoundedRectangle(cornerRadius: PbRadius.button).stroke(Color.cardBorder, lineWidth: 1))
            .brightness(configuration.isPressed ? -0.04 : 0)
            .contentShape(RoundedRectangle(cornerRadius: PbRadius.button))
    }
}

#if DEBUG
private struct QuietButtonPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            Button("Continue in terminal") {}.buttonStyle(QuietButtonStyle())
            Button("Take over") {}.buttonStyle(QuietButtonStyle()).disabled(true)
            Button {} label: { Image(systemName: "sidebar.right") }.buttonStyle(QuietButtonStyle(isSelected: true))
            Button {} label: { Label("Copy", systemImage: "doc.on.doc").frame(width: 140) }.buttonStyle(QuietButtonStyle(isFilled: false))
        }
        .padding()
        .background(Color.windowBG)
    }
}

#Preview("QuietButton - light") { QuietButtonPreview().preferredColorScheme(.light) }
#Preview("QuietButton - dark") { QuietButtonPreview().preferredColorScheme(.dark) }
#endif
