import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - RuntimeSetupWelcomeView

/// Approved M04 runtime setup states; presentation never starts acquisition automatically.
struct RuntimeSetupWelcomeView: View {
    var state: RuntimeSetupState = .installationRequired(installedVersion: nil, requiredVersion: HarflowVersion.current)
    var action: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
.font(.hf(.title, weight: .semibold))
                    .accessibilityIdentifier("runtimeSetup.welcomeTitle")
                Text(state.detail)
.font(.hf(.body))
.foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(isFailure ? "runtimeSetup.error" : "runtimeSetup.welcomeBody")
                if state.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel(state.title)
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
.buttonStyle(MonitorButtonStyle(.glass))
                        .accessibilityIdentifier("runtimeSetup.action")
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
            .padding(.top, 88)
            .background(ScrollChrome())
        }
        .background(Color.windowBG)
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

#if DEBUG
#Preview("Setup required, light") {
    RuntimeSetupWelcomeView().frame(width: 800, height: 600).preferredColorScheme(.light)
}

#Preview("Setup required, dark") {
    RuntimeSetupWelcomeView().frame(width: 800, height: 600).preferredColorScheme(.dark)
}
#endif
