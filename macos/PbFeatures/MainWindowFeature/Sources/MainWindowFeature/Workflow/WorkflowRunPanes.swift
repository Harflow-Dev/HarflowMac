import PbUI
import SwiftUI

// MARK: - WorkflowRunLayout

/// One source of pane constraints for the loading and loaded run views. The values are the
/// existing native split contracts, named; the plan panel's ideal width follows SPEC §6.4 (~288).
enum WorkflowRunLayout {
    static let canvasMinimum: CGFloat = PbRadius.Metrics.workflowRunCanvasMinimumHeight
    static let canvasIdeal: CGFloat = PbRadius.Metrics.workflowRunCanvasIdealHeight
    static let activityMinimum: CGFloat = PbRadius.Metrics.workflowRunActivityMinimumHeight
    static let inspectorMinimum: CGFloat = PbRadius.Metrics.workflowRunPanelMinimumWidth
    static let inspectorIdeal: CGFloat = PbRadius.Metrics.workflowRunPanelIdealWidth
    static let inspectorMaximum: CGFloat = PbRadius.Metrics.workflowRunPanelMaximumWidth

    static func minimums(height: CGFloat) -> (canvas: CGFloat, activity: CGFloat) {
        let available = max(0, height - 2)
        let scale = min(1, available / (canvasMinimum + activityMinimum))
        return (canvasMinimum * scale, activityMinimum * scale)
    }
}

// MARK: - WorkflowRunPanes

/// Keeps split-view identity and divider positions when placeholders become real content.
struct WorkflowRunPanes<Canvas: View, Inspector: View, Activity: View>: View {
    let isGraph: Bool
    var isLoading = false
    @State private var splitSnapshot = WorkflowRunSplitSnapshot()
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let inspector: () -> Inspector
    @ViewBuilder let activity: () -> Activity

    var body: some View {
        if isGraph {
            GeometryReader { viewport in
                let minimums = WorkflowRunLayout.minimums(height: viewport.size.height)
                WorkflowPaneViewport {
                VSplitView {
                    HSplitView {
                    canvas().frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity, minHeight: PbRadius.Metrics.zero, maxHeight: .infinity).clipped()
                    sidebar
                    }.frame(minHeight: minimums.canvas, idealHeight: min(WorkflowRunLayout.canvasIdeal, viewport.size.height * 0.6))
                    activity().frame(minHeight: minimums.activity)
                }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
            }
        } else {
            WorkflowPaneViewport { HSplitView { activity(); sidebar } }
        }
    }

    private var sidebar: some View {
        inspector()
.frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity, minHeight: PbRadius.Metrics.zero, maxHeight: .infinity)
.clipped()
            .frame(minWidth: WorkflowRunLayout.inspectorMinimum, idealWidth: WorkflowRunLayout.inspectorIdeal,
                          maxWidth: WorkflowRunLayout.inspectorMaximum)
            .background(WorkflowRunSplitPosition(isLoading: isLoading, snapshot: splitSnapshot))
    }
}

#if DEBUG
#Preview {
    WorkflowRunPanes(isGraph: true) { Color.cardFill.opacity(0) } inspector: { Color.neutralFill } activity: { Color.cardFill.opacity(0) }
        .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.workflowPreviewHeight)
}
#endif
