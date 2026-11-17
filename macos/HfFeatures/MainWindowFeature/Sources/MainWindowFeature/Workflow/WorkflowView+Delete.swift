import HfUI
import SwiftUI

// MARK: - WorkflowView Delete

extension WorkflowView {
    @ViewBuilder
    var deleteFailureBanner: some View {
        if let reason = viewModel.deleteFailureText {
            Banner(icon: "exclamationmark.triangle", title: "Couldn’t delete the workflow.",
                   text: reason, tint: .failedRed)
                .padding(HfRadius.Metrics.spacing12)
            Divider()
        }
    }
}
