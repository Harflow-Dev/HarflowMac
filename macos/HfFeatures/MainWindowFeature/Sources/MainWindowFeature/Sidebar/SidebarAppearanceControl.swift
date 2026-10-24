import HfRepository
import HfUI
import SwiftUI

// MARK: - SidebarAppearanceControl

/// Compact application-wide appearance choices shown in the sidebar footer.
struct SidebarAppearanceControl: View {
    let appearance: AppAppearance
    let onSelect: (AppAppearance) -> Void

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing4) {
            ForEach(AppAppearance.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    Image(systemName: symbol(for: option))
                        .font(.hf(.caption, weight: .medium))
                        .frame(width: HfRadius.Metrics.appearanceControlSize, height: HfRadius.Metrics.appearanceControlSize)
                        .background {
                            RoundedRectangle(cornerRadius: HfRadius.button)
                                .fill(appearance == option ? Color.pillFill : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: HfRadius.button)
                                .strokeBorder(
                                    appearance == option ? Color.secondaryText.opacity(0.45) : Color.clear,
                                    lineWidth: HfRadius.Metrics.hairlineStroke
                                )
                        }
                }
                .buttonStyle(.borderless)
                .help(help(for: option))
                .accessibilityLabel(title(for: option))
                .accessibilityValue(appearance == option ? "Selected" : "")
                .accessibilityAddTraits(appearance == option ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
        .accessibilityValue(title(for: appearance))
    }

    private func symbol(for appearance: AppAppearance) -> String {
        switch appearance {
        case .light: "sun.max"
        case .dark: "moon"
        case .system: "desktopcomputer"
        }
    }

    private func title(for appearance: AppAppearance) -> String {
        switch appearance {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    private func help(for appearance: AppAppearance) -> String {
        appearance == .system ? "System — follows this Mac" : title(for: appearance)
    }
}

#if DEBUG
#Preview("Appearance control - light") {
    SidebarAppearanceControl(appearance: .system, onSelect: { _ in })
        .padding(HfRadius.Metrics.spacing16)
        .preferredColorScheme(.light)
}

#Preview("Appearance control - dark") {
    SidebarAppearanceControl(appearance: .dark, onSelect: { _ in })
        .padding(HfRadius.Metrics.spacing16)
        .preferredColorScheme(.dark)
}
#endif
