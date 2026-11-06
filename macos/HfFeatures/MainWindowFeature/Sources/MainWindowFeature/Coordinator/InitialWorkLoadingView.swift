import HfUI
import SwiftUI

// MARK: - InitialWorkLoadingView

/// Approved m04-proposal/runtime-listing: a qualified runtime is never an installation failure.
struct InitialWorkLoadingView: View {
    let error: String?
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Runtime ready").font(.hf(.title, weight: .semibold))
                if let error {
                    Text("Your runtime is ready. Recent work could not be loaded.")
                    Text(error).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                    Button("Retry loading work", action: retry)
                        .buttonStyle(MonitorButtonStyle(.glass))
                } else {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading your work for the first time…")
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
            .padding(.top, 88)
            .background(ScrollChrome())
        }
        .background(Color.windowBG)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runtime-listing")
    }
}

#if DEBUG
#Preview("First listing") {
    InitialWorkLoadingView(error: nil, retry: {}).frame(width: 1000, height: 620)
}

#Preview("First listing failed") {
    InitialWorkLoadingView(error: "The public task listing is unavailable.", retry: {})
        .frame(width: 1000, height: 620)
}
#endif
