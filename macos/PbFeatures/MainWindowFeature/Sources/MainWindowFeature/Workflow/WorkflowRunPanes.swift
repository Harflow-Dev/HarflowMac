import SwiftUI

// MARK: - WorkflowRunLayout

/// One source of pane constraints for the loading and loaded run views.
enum WorkflowRunLayout {
    static let canvasMinimum: CGFloat = 170
    static let canvasIdeal: CGFloat = 300
    static let activityMinimum: CGFloat = 240
    static let inspectorMinimum: CGFloat = 220
    static let inspectorIdeal: CGFloat = 260
    static let inspectorMaximum: CGFloat = 500

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
                    canvas().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
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
.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
.clipped()
            .frame(minWidth: WorkflowRunLayout.inspectorMinimum, idealWidth: WorkflowRunLayout.inspectorIdeal,
                          maxWidth: WorkflowRunLayout.inspectorMaximum)
            .background(WorkflowRunSplitPosition(isLoading: isLoading, snapshot: splitSnapshot))
    }
}

#if DEBUG
#Preview {
    WorkflowRunPanes(isGraph: true) { Color.clear } inspector: { Color.gray } activity: { Color.clear }
        .frame(width: 1000, height: 700)
}
#endif
