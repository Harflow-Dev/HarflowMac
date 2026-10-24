import HfRepository
import SwiftUI

// MARK: - RuntimeSetupCard

/// Compact first-run surface; settings and appearance remain in the sidebar footer.
struct RuntimeSetupCard: View {
    let state: RuntimeSetupState
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title)
.foregroundStyle(.secondary)
.accessibilityHidden(true)
            Text(state.title).font(.headline)
            Text(state.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if state.isBusy { ProgressView().controlSize(.small).accessibilityLabel(state.title) }
            if let title = state.actionTitle {
                Button(title, action: action)
.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("runtime-setup-action")
            }
        }
        .padding()
.frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
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
