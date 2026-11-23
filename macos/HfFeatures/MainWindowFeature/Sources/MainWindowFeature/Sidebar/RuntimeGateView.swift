import AppKit
import HfUI
import SwiftUI

// MARK: - RuntimeGateDetailRow

/// One detail line of a gate: a caption label above a monospaced, selectable value.
struct RuntimeGateDetailRow: Equatable {
    let label: String
    let value: String
}

// MARK: - RuntimeGateView

/// The main-pane gate shared by runtime setup and the first task listing.
///
/// The gate matches HarflowDesign `harness-runtime` (pin 5b37a3d): a 620 pt box with 32 pt padding,
/// 120 pt below the top of the pane, a 26/32 title, 14/22 body and status text in the primary colour,
/// one small secondary action and no spinner.
struct RuntimeGateView: View {
    let title: String
    let bodyText: String
    var statusText: String?
    var statusIsFailure = false
    /// Draws the status in the secondary colour, as the engine and runtime gates do.
    var statusIsSecondary = false
    /// Detail lines drawn between the body and the status. Empty for the setup and listing gates.
    var detailRows: [RuntimeGateDetailRow] = []
    var actionTitle: String?
    /// Draws the action as a link that opens the Settings window instead of calling `action`.
    var actionOpensSettings = false
    var action: () -> Void = {}

    @ViewBuilder private func actionControl(_ title: String) -> some View {
        if actionOpensSettings {
            SettingsLink { Text(title) }
        } else {
            Button(title, action: action)
        }
    }

    private static let titleText = TaskScreenStyle.TextSpec(size: 26, lineHeight: 32)
    private static let bodyTextSpec = TaskScreenStyle.TextSpec(size: 14, lineHeight: 22)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(Font(NSFont.systemFont(ofSize: Self.titleText.size, weight: .semibold)))
                    .tracking(-0.26)
                    .lineSpacing(TaskScreenStyle.lineSpacing(Self.titleText))
                    .foregroundStyle(Color.primaryText)
                    .accessibilityIdentifier("runtimeSetup.welcomeTitle")
                Text(bodyText)
                    .font(TaskScreenStyle.sans(size: Self.bodyTextSpec.size))
                    .lineSpacing(TaskScreenStyle.lineSpacing(Self.bodyTextSpec))
                    .foregroundStyle(Color.primaryText)
                    .accessibilityIdentifier("runtimeSetup.welcomeBody")
                if !detailRows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(detailRows, id: \.label) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.label)
                                    .font(.hf(.caption))
                                    .foregroundStyle(Color.secondaryText)
                                Text(row.value)
                                    .font(.hf(.secondary, design: .monospaced))
                                    .foregroundStyle(Color.primaryText)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("runtimeSetup.detail.\(row.label)")
                        }
                    }
                    .padding(.top, 4)
                }
                if let statusText {
                    Text(statusText)
                        .font(TaskScreenStyle.sans(size: Self.bodyTextSpec.size))
                        .lineSpacing(TaskScreenStyle.lineSpacing(Self.bodyTextSpec))
                        .foregroundStyle(statusIsSecondary ? Color.secondaryText : Color.primaryText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(statusIsFailure ? "runtimeSetup.error" : "runtimeSetup.status")
                }
                if let actionTitle {
                    actionControl(actionTitle)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("runtimeSetup.action")
                        // The drawn column keeps an empty status row, so the body-to-action gap is 32.
                        .padding(.top, statusText == nil ? 16 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
            .background(ScrollChrome())
        }
        .background(Color.windowBG)
        .onChange(of: statusText) { _, new in
            if let new, !new.isEmpty { RuntimeSetupAnnouncement.requested(new) }
        }
    }
}

// MARK: - RuntimeSetupAnnouncement

/// SwiftUI on macOS has no status role, so a changed status line is announced explicitly.
@MainActor private enum RuntimeSetupAnnouncement {
    static func requested(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

#if DEBUG
#Preview("Gate with action, light") {
    RuntimeGateView(title: "Runtime ready", bodyText: "Your runtime is ready. Recent work could not be loaded.",
                    actionTitle: "Retry loading work")
        .frame(width: 800, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Gate with failure status, dark") {
    RuntimeGateView(title: "Runtime ready", bodyText: "Your runtime is ready. Recent work could not be loaded.",
                    statusText: "The public task listing is unavailable.", statusIsFailure: true,
                    actionTitle: "Retry loading work")
        .frame(width: 800, height: 600)
        .preferredColorScheme(.dark)
}
#endif
