import SwiftUI

// MARK: - InitialWorkLoadingView

/// Approved m04-proposal/runtime-listing: a qualified runtime is never an installation failure.
///
/// Draws the same gate as runtime setup so the pane does not shift when setup finishes. Unlike the
/// drawing, a failed listing also shows the failure message as selectable status text.
struct InitialWorkLoadingView: View {
    let error: String?
    let retry: () -> Void

    var body: some View {
        RuntimeGateView(
            title: "Runtime ready",
            bodyText: error == nil
                ? "Loading your work for the first time…"
                : "Your runtime is ready. Recent work could not be loaded.",
            statusText: error,
            statusIsFailure: true,
            actionTitle: error == nil ? nil : "Retry loading work",
            action: retry
        )
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
