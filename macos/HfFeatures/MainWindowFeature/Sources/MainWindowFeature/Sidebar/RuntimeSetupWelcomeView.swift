import AppKit
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - RuntimeSetupWelcomeView

/// Approved M04 runtime setup states; presentation never starts acquisition automatically.
///
/// The gate matches HarflowDesign `harness-runtime` (pin 5b37a3d): a 620 pt box with 32 pt padding,
/// 120 pt below the top of the pane, a 26/32 title, 14/22 body and status text in the primary colour,
/// one small secondary action and no spinner.
struct RuntimeSetupWelcomeView: View {
    var state: RuntimeSetupState = .installationRequired(installedVersion: nil, requiredVersion: HarflowVersion.current)
    var action: () -> Void = {}

    private static let titleText = TaskScreenStyle.TextSpec(size: 26, lineHeight: 32)
    private static let bodyText = TaskScreenStyle.TextSpec(size: 14, lineHeight: 22)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(Font(NSFont.systemFont(ofSize: Self.titleText.size, weight: .semibold)))
                    .tracking(-0.26)
                    .lineSpacing(TaskScreenStyle.lineSpacing(Self.titleText))
                    .foregroundStyle(Color.primaryText)
                    .accessibilityIdentifier("runtimeSetup.welcomeTitle")
                Text(bodyCopy)
                    .font(TaskScreenStyle.sans(size: Self.bodyText.size))
                    .lineSpacing(TaskScreenStyle.lineSpacing(Self.bodyText))
                    .foregroundStyle(Color.primaryText)
                    .accessibilityIdentifier("runtimeSetup.welcomeBody")
                if let statusText {
                    Text(statusText)
                        .font(TaskScreenStyle.sans(size: Self.bodyText.size))
                        .lineSpacing(TaskScreenStyle.lineSpacing(Self.bodyText))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(isFailure ? "runtimeSetup.error" : "runtimeSetup.status")
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
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

    private var bodyCopy: String {
        switch state {
        case .checking: "Checking the managed runtime before loading your work."
        case .installationRequired(let installed, let required):
            installed.map { "Installed \($0) · required \(required)" } ?? "The required runtime is not installed."
        case .installing, .updating: "Preparing and verifying the required runtime…"
        case .failed: "Review the failure and retry when ready."
        case .updateFailed: "The installed runtime was kept. Review the failure and retry when ready."
        case .ready: state.detail
        }
    }

    private var statusText: String? {
        switch state {
        case .installing: "Installation in progress"
        case .updating: "Update in progress"
        case .failed(let message), .updateFailed(let message, _, _): message
        default: nil
        }
    }

    private var isFailure: Bool {
        switch state {
        case .failed, .updateFailed: true
        default: false
        }
    }

    private var title: String {
        switch state {
        case .checking: "Checking Harflow runtime"
        case .installationRequired(let installed, _): installed == nil ? "Set up Harflow" : "Update required"
        case .installing: "Installing runtime"
        case .updating: "Updating runtime"
        case .failed: "Setup could not finish"
        case .updateFailed: "Update could not finish"
        case .ready: "Runtime ready"
        }
    }

    private var actionTitle: String? {
        switch state {
        case .installationRequired(let installed, _): installed == nil ? "Install runtime" : "Update runtime"
        case .failed, .updateFailed: "Retry setup"
        default: nil
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
#Preview("Setup required, light") {
    RuntimeSetupWelcomeView().frame(width: 800, height: 600).preferredColorScheme(.light)
}

#Preview("Setup required, dark") {
    RuntimeSetupWelcomeView().frame(width: 800, height: 600).preferredColorScheme(.dark)
}

#Preview("Installing, light") {
    RuntimeSetupWelcomeView(state: .installing).frame(width: 800, height: 600).preferredColorScheme(.light)
}

#Preview("Failed, dark") {
    RuntimeSetupWelcomeView(state: .failed("The managed runtime could not be prepared."))
        .frame(width: 800, height: 600)
        .preferredColorScheme(.dark)
}
#endif
