import HfRepository
import MonitorCore
import SwiftUI

// MARK: - RuntimeSetupWelcomeView

/// Approved M04 runtime setup states; presentation never starts acquisition automatically.
///
/// This view maps each state to its copy; `RuntimeGateView` draws the gate (HarflowDesign
/// `harness-runtime`, pin 5b37a3d).
struct RuntimeSetupWelcomeView: View {
    var state: RuntimeSetupState = .installationRequired(installedVersion: nil, requiredVersion: HarflowVersion.current)
    /// A task link is waiting for the runtime; the gate then tells the person it opens after setup.
    var holdsTaskLink = false
    var action: () -> Void = {}

    /// Design wording of the held-link status line (`harness-runtime/deep-link-held`, HarflowDesign e1c9230).
    nonisolated static let heldTaskLinkStatus = "After setup, Harflow opens the task you linked to."

    var body: some View {
        RuntimeGateView(title: title, bodyText: bodyCopy, statusText: statusText, statusIsFailure: isFailure,
                        actionTitle: actionTitle, action: action)
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

    private var statusText: String? { Self.statusText(for: state, holdsTaskLink: holdsTaskLink) }

    /// The gate's status line. The held-link line shows only where the status line is otherwise empty: while checking,
    /// when installation is required and when an update is required. Installing, updating and the failures keep
    /// their own status.
    nonisolated static func statusText(for state: RuntimeSetupState, holdsTaskLink: Bool) -> String? {
        switch state {
        case .installing: "Installation in progress"
        case .updating: "Update in progress"
        case .failed(let message), .updateFailed(let message, _, _): message
        case .checking, .installationRequired: holdsTaskLink ? heldTaskLinkStatus : nil
        case .ready: nil
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
