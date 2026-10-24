import HfRepository
import HfUI
import SwiftUI

// MARK: - RuntimeSetupCard

/// Compact first-run surface; settings and appearance remain in the sidebar footer.
struct RuntimeSetupCard: View {
    let state: RuntimeSetupState
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.setupCardSpacing) {
            Text(eyebrow)
                .font(.hf(.setupEyebrow, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .tracking(HfRadius.Metrics.setupEyebrowTracking)

            Text(state.title)
                .font(.hf(.reading, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("runtimeSetup.title")

            Text(detail)
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let versions = versionRows {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.setupVersionRowSpacing) {
                    ForEach(versions) { version in
                        versionRow(version)
                    }
                }
            }

            if preservesExistingInstallation {
                Text(preservationNote)
                    .font(.hf(.setupFootnote))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(state.title)
            }

            if let diagnostic {
                Text(diagnostic)
                    .font(.hf(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("runtimeSetup.error")
            }

            if let title = state.actionTitle {
                Button(title, action: action)
                    .buttonStyle(RuntimeSetupButtonStyle())
                    .accessibilityIdentifier("runtimeSetup.action")
            }
        }
        .padding(HfRadius.Metrics.setupCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HfRadius.card)
                .fill(Color.cardFill)
                .overlay {
                    RoundedRectangle(cornerRadius: HfRadius.card)
                        .stroke(Color.cardBorder, lineWidth: HfRadius.Metrics.hairlineStroke)
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runtimeSetup.card")
    }

    private var detail: String {
        switch state {
        case .checking:
            "Checking the managed installation on this Mac."
        case .installationRequired(let installed, _):
            installed == nil
                ? "Install the components Harflow needs to run."
                : "This version of Harflow needs updated components."
        case .installing:
            "Installing required components for this app."
        case .updating:
            "Installing the update. Your task history is preserved during the update."
        case .updateFailed:
            "Your history and existing installation have been kept."
        case .failed:
            "The required components could not be installed. No session has started; try again."
        case .ready:
            "MCP registrations are managed separately in Harnesses."
        }
    }

    private var versionRows: [SetupVersion]? {
        switch state {
        case .installationRequired(let installed, let required):
            guard let installed else { return nil }
            return [SetupVersion(label: "Installed", value: installed),
                    SetupVersion(label: "Required by this app", value: required)]
        default:
            return nil
        }
    }

    private var eyebrow: String {
        switch state {
        case .installationRequired(let installed, _): installed == nil ? "FIRST-TIME SETUP" : "UPDATE REQUIRED"
        case .updating, .updateFailed: "UPDATE REQUIRED"
        default: "FIRST-TIME SETUP"
        }
    }

    private var preservesExistingInstallation: Bool {
        switch state {
        case .installationRequired(let installed, _): installed != nil
        default: false
        }
    }

    private var preservationNote: String {
        "Your task history and existing installation are kept while Harflow updates."
    }

    private var diagnostic: String? {
        switch state {
        case .failed(let message), .updateFailed(let message, _, _): message
        default: nil
        }
    }

    private func versionRow(_ version: SetupVersion) -> some View {
        HStack {
            Text(version.label)
                .foregroundStyle(Color.secondaryText)
            Spacer(minLength: HfRadius.Metrics.spacing8)
            Text(version.value)
                .foregroundStyle(Color.primaryText)
                .monospacedDigit()
        }
        .font(.hf(.setupFootnote))
        .padding(.vertical, HfRadius.Metrics.spacing4)
        .overlay(alignment: .top) {
            Color.cardBorder.frame(height: HfRadius.Metrics.hairlineStroke)
        }
    }
}

// MARK: - SetupVersion

private struct SetupVersion: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

// MARK: - RuntimeSetupButtonStyle

private struct RuntimeSetupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hf(.caption, weight: .semibold))
            .foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity, minHeight: HfRadius.Metrics.setupButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: HfRadius.button)
                    .fill(Color.accentFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: HfRadius.button))
    }
}

#if DEBUG
#Preview("Runtime setup") {
    RuntimeSetupCard(state: .installationRequired(installedVersion: nil, requiredVersion: "0.0.2"), action: {})
        .padding()
        .frame(width: 272)
}

#Preview("Runtime setup failure") {
    RuntimeSetupCard(state: .failed("The exact paired engine release is unavailable."), action: {})
        .padding()
        .frame(width: 272)
}
#endif
