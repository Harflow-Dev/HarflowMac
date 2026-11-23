import SwiftUI

// MARK: - InitialWorkLoadingView

/// Approved m04-proposal/runtime-listing: a qualified runtime is never an installation failure.
///
/// Draws the same gate as runtime setup so the pane does not shift when setup finishes. Unlike the
/// drawing, a failed listing also shows the failure message as selectable status text.
struct InitialWorkLoadingView: View {
    let error: LoadingWorkError?
    let retry: () -> Void

    var body: some View {
        RuntimeGateView(
            title: "Runtime ready",
            bodyText: error == nil
                ? "Loading your work for the first time…"
                : "Your runtime is ready. Recent work could not be loaded.",
            statusText: error?.message,
            statusIsFailure: true,
            detailRows: error?.code.map { [RuntimeGateDetailRow(label: "Code", value: $0)] } ?? [],
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
    InitialWorkLoadingView(error: LoadingWorkError(message: "The public task listing is unavailable.", code: "unavailable"), retry: {})
        .frame(width: 1000, height: 620)
}
#endif
