import HfUI
import SwiftUI

// MARK: - WorkflowRecoveryPaneHead

/// The recovery pane's fixed head: `Recovery options` and the run's status badge, no close. It stays outside the pane's
/// scrolling body so the title and badge remain visible however long the question or instructions grow.
struct WorkflowRecoveryPaneHead: View {
    let run: WorkflowRunModel

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Text("Recovery options")
                .font(.hf(.body, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            StatusBadge(
                status: .other(run.status),
                presentationOverride: WorkflowRunStatusBadge.presentation(status: run.status, isSettling: run.isSettling)
            )
            Spacer(minLength: HfRadius.Metrics.zero)
        }
        .padding(.horizontal, HfRadius.Metrics.spacing16)
        .padding(.vertical, HfRadius.Metrics.spacing12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-recovery-pane-head")
    }
}

#if DEBUG
#Preview("Recovery pane head - light") {
    VStack(spacing: HfRadius.Metrics.zero) {
        if let run = WorkflowPreview.make(run: true).selectedRun { WorkflowRecoveryPaneHead(run: run) }
        Divider()
    }
    .frame(width: HfRadius.Metrics.workflowRunRecoveryPanelIdealWidth)
    .preferredColorScheme(.light)
}

#Preview("Recovery pane head - dark") {
    VStack(spacing: HfRadius.Metrics.zero) {
        if let run = WorkflowPreview.make(run: true).selectedRun { WorkflowRecoveryPaneHead(run: run) }
        Divider()
    }
    .frame(width: HfRadius.Metrics.workflowRunRecoveryPanelIdealWidth)
    .preferredColorScheme(.dark)
}
#endif
