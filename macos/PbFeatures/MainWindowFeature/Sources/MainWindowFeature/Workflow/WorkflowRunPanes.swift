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
            VSplitView {
                HSplitView {
                    canvas().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                    sidebar
                }.frame(minHeight: WorkflowRunLayout.canvasMinimum, idealHeight: WorkflowRunLayout.canvasIdeal)
                activity().frame(minHeight: WorkflowRunLayout.activityMinimum)
            }
        } else {
            HSplitView { activity(); sidebar }
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
