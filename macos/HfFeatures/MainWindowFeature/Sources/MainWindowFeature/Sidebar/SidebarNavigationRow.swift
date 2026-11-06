import HfCommon
import HfUI
import SwiftUI

// MARK: - SidebarNavigationRow

/// One unified-scroll navigation row (M04 `.hd-m04-sidebar-scroll`): a normal 32 pt native row
/// with the rail's exact template artwork, the Needs you capsule and the New task shortcut hint.
/// Selection stays owned by the outline — no embedded button, so clicks, type-select and
/// keyboard move through one selection path.
struct SidebarNavigationRow: View {
    /// The verified prototype's normal row height; never below an accessibility-driven minimum.
    private static let normalRowHeight: CGFloat = 32

    let navigation: SidebarNavigationEntry
    let minimumHeight: Double

    var body: some View {
        HStack(spacing: HfRadius.Metrics.rowItemSpacing) {
            SidebarNavigationIcon(navigation.artwork, size: 16).frame(width: 18)
            Text(navigation.title)
            Spacer(minLength: HfRadius.Metrics.zero)
            if let shortcut = navigation.shortcut {
                Text(shortcut)
                    .font(.hf(.caption))
                    .foregroundStyle(Color.tertiaryText)
                    .accessibilityHidden(true)
            }
            if let badgeText = navigation.badge.capsuleText {
                Text(badgeText)
                    .font(.hf(.caption, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, HfRadius.Metrics.spacing6)
                    .background(Color.warningBG, in: Capsule())
                    .foregroundStyle(Color.warningFG)
                    .accessibilityHidden(true)
            }
        }
        .font(.hf(.body))
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: max(Self.normalRowHeight, minimumHeight), alignment: .leading)
        .accessibilityIdentifier("sidebar-navigation-\(navigation.title)")
        .accessibilityLabel(accessibilityLabel)
    }

    /// The Needs you row carries its count like its former header and Overview representations.
    private var accessibilityLabel: String {
        navigation.destination == .needsYou(itemID: nil) ? navigation.badge.accessibilityLabel : navigation.title
    }
}

#if DEBUG
#Preview("Sidebar navigation row - light") {
    VStack(alignment: .leading) {
        ForEach(SidebarNavigationEntry.unifiedEntries(badge: .count(7, atLeast: true)), id: \.id) { entry in
            SidebarNavigationRow(navigation: entry, minimumHeight: 0)
        }
    }
    .frame(width: HfRadius.Metrics.sidebarPreviewWidth)
    .preferredColorScheme(.light)
}

#Preview("Sidebar navigation row - dark") {
    VStack(alignment: .leading) {
        ForEach(SidebarNavigationEntry.unifiedEntries(badge: .none), id: \.id) { entry in
            SidebarNavigationRow(navigation: entry, minimumHeight: 0)
        }
    }
    .frame(width: HfRadius.Metrics.sidebarPreviewWidth)
    .preferredColorScheme(.dark)
}
#endif
