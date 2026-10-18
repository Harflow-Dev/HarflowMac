import HfUI
import SwiftUI

#if DEBUG
/// A selected run renders the run sidebar (scoped chrome on its own scroll views), the
/// diagnostics viewport and the recovery-eligible badge. Dummy preview data only.
#Preview("Workflow run - light") {
    WorkflowView(WorkflowPreview.make(run: true))
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.foundationHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow run - dark") {
    WorkflowView(WorkflowPreview.make(run: true))
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.foundationHeight)
        .preferredColorScheme(.dark)
}
#endif
