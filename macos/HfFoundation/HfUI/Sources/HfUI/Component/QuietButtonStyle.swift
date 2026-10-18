import SwiftUI

// MARK: - QuietButtonStyle

/// The design's toolbar button: a small neutral fill with a hairline border and button radius, in
/// the normal text colour — present, but not competing with the content. It draws its own
/// background, so a toolbar can neither strip it (a plain toolbar button is bezel-less until hover)
/// nor wrap it in a glass capsule. Glass stays opt-in through `MonitorButtonStyle(.glass)`; this
/// style serves content and toolbar callsites alike and never takes glass globally. A destructive
/// button is the tinted danger style: `dangerFG` on a `dangerBG` capsule (SPEC §4/§5.3).
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

    private var isDestructive: Bool { configuration.role == .destructive }

    var body: some View {
        if isDestructive {
            configuration.label
                .font(.hf(.body, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.dangerFG : Color.dangerFG.opacity(0.5))
                .padding(.horizontal, HfRadius.Metrics.spacing10)
                .padding(.vertical, HfRadius.Metrics.spacing4)
                .background(Capsule().fill(Color.dangerBG))
                .brightness(configuration.isPressed ? -0.04 : 0)
                .contentShape(Capsule())
        } else {
            configuration.label
                .font(.hf(.body))
                .foregroundStyle(isEnabled ? Color.primaryText : Color.secondaryText)
                .padding(.horizontal, HfRadius.Metrics.spacing10)
                .padding(.vertical, HfRadius.Metrics.spacing4)
                .background(
                    RoundedRectangle(cornerRadius: HfRadius.button)
                        .fill(Color.pillFill.opacity(configuration.isPressed || isSelected ? 1 : (isFilled ? 0.75 : 0)))
                )
                .overlay(RoundedRectangle(cornerRadius: HfRadius.button).stroke(Color.cardBorder, lineWidth: HfRadius.Metrics.hairlineStroke))
                .brightness(configuration.isPressed ? -0.04 : 0)
                .contentShape(RoundedRectangle(cornerRadius: HfRadius.button))
        }
    }
}

#if DEBUG
private struct QuietButtonPreview: View {
    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing12) {
            Button("Continue in terminal") {}.buttonStyle(QuietButtonStyle())
            Button("Take over") {}.buttonStyle(QuietButtonStyle()).disabled(true)
            Button("Cancel all", role: .destructive) {}.buttonStyle(QuietButtonStyle())
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
