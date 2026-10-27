import HfUI
import SwiftUI

// MARK: - RuntimeSetupWelcomeView

/// Quiet detail-pane explanation while the managed runtime is unavailable.
struct RuntimeSetupWelcomeView: View {
    var body: some View {
        VStack(spacing: HfRadius.Metrics.spacing10) {
            if let image = MainWindowEmblem.image {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.primaryText)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
            }

            Text("SETUP REQUIRED")
                .font(.hf(.setupEyebrow, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
                .tracking(HfRadius.Metrics.setupEyebrowTracking)

            Text("Finish setting up Harflow")
                .font(.hf(.setupWelcomeTitle, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("runtimeSetup.welcomeTitle")

            Text("Once the runtime components required by this app are ready, sessions and workflows will be available here.")
                .font(.hf(.body))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: HfRadius.Metrics.setupWelcomeTextWidth)
                .accessibilityIdentifier("runtimeSetup.welcomeBody")
        }
        .frame(maxWidth: HfRadius.Metrics.setupWelcomeTextWidth)
        .padding(.horizontal, HfRadius.Metrics.spacing24)
        .frame(maxWidth: HfRadius.Metrics.setupWelcomeContainerWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.windowBG)
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
