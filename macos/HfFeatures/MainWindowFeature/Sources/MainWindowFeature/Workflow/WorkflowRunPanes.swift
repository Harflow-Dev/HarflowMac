import HfUI
import SwiftUI

// MARK: - WorkflowRunLayout

/// One source of pane constraints for the loading and loaded run views. The values are the
/// native split contracts, with a run inspector matching the activity reading width.
enum WorkflowRunLayout {
    static let canvasMinimum: CGFloat = HfRadius.Metrics.workflowRunCanvasMinimumHeight
    static let canvasIdeal: CGFloat = HfRadius.Metrics.workflowRunCanvasIdealHeight
    static let activityMinimum: CGFloat = HfRadius.Metrics.workflowRunActivityMinimumHeight
    static let inspectorMinimum: CGFloat = HfRadius.Metrics.workflowRunPanelMinimumWidth
    static let inspectorIdeal: CGFloat = ParallelLayout.minimumColumnWidth
    static let inspectorMaximum: CGFloat = HfRadius.Metrics.workflowRunPanelMaximumWidth

    static func minimums(height: CGFloat, canvasChromeHeight: CGFloat = 0) -> (canvas: CGFloat, activity: CGFloat) {
        let available = max(0, height - 2)
        let chrome = min(available, max(0, canvasChromeHeight))
        let scale = min(1, (available - chrome) / (canvasMinimum + activityMinimum))
        return (chrome + canvasMinimum * scale, activityMinimum * scale)
    }
}

// MARK: - WorkflowRunPanes

/// Keeps split-view identity and divider positions when placeholders become real content.
struct WorkflowRunPanes<Canvas: View, Inspector: View, Activity: View>: View {
    let isGraph: Bool
    var isLoading = false
    var canvasChromeHeight: CGFloat = 0
    @State private var splitSnapshot = WorkflowRunSplitSnapshot()
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let inspector: () -> Inspector
    @ViewBuilder let activity: () -> Activity

    var body: some View {
        if isGraph {
            WorkflowPaneViewport {
                HSplitView {
                    canvas()
.frame(minWidth: WorkflowInspectorWidth.canvasMinimumWidth, maxWidth: .infinity,
                                   minHeight: 0, maxHeight: .infinity)
.clipped()
                    sidebar
                }
            }
        } else {
            WorkflowPaneViewport { HSplitView { activity(); sidebar } }
        }
    }

    private var sidebar: some View {
        inspector()
.frame(minWidth: HfRadius.Metrics.zero, maxWidth: .infinity, minHeight: HfRadius.Metrics.zero, maxHeight: .infinity)
.clipped()
            .frame(minWidth: WorkflowRunLayout.inspectorMinimum, idealWidth: WorkflowRunLayout.inspectorIdeal,
                          maxWidth: WorkflowRunLayout.inspectorMaximum)
            .background(WorkflowRunSplitPosition(isLoading: isLoading, snapshot: splitSnapshot))
    }
}

#if DEBUG
#Preview {
    WorkflowRunPanes(isGraph: true) { Color.cardFill.opacity(0) } inspector: { Color.neutralFill } activity: { Color.cardFill.opacity(0) }
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.workflowPreviewHeight)
}
#endif
