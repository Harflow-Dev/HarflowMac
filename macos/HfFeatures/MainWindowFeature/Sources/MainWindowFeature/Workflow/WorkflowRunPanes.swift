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
    static let defaultInspectorIdeal: CGFloat = HfRadius.Metrics.workflowRunPanelIdealWidth
    static let inspectorIdeal: CGFloat = HfRadius.Metrics.workflowRunActivityPanelIdealWidth
    static let inspectorMaximum: CGFloat = HfRadius.Metrics.workflowRunPanelMaximumWidth

    static let recoveryInspectorIdeal: CGFloat = HfRadius.Metrics.workflowRunRecoveryPanelIdealWidth

    static func inspectorIdeal(for presentation: WorkflowRunPaneSizing) -> CGFloat {
        switch presentation {
        case .default: defaultInspectorIdeal
        case .activity: inspectorIdeal
        case .recovery: recoveryInspectorIdeal
        }
    }

    static func minimums(height: CGFloat, canvasChromeHeight: CGFloat = 0) -> (canvas: CGFloat, activity: CGFloat) {
        let available = max(0, height - 2)
        let chrome = min(available, max(0, canvasChromeHeight))
        let scale = min(1, (available - chrome) / (canvasMinimum + activityMinimum))
        return (chrome + canvasMinimum * scale, activityMinimum * scale)
    }
}

enum WorkflowRunPaneSizing: Hashable {
    case `default`
    case activity
    /// The recovery pane: the default sidebar's content re-headed, at the approved state's width.
    case recovery

    /// Whether the default inspector's scroll view belongs to this presentation. Only `.default` saves and restores
    /// the default sidebar's scroll origin; the activity feed and the recovery pane never capture it.
    var ownsDefaultInspectorScroll: Bool { self == .default }
}

// MARK: - WorkflowRunPanes

/// Keeps split-view identity and divider positions when placeholders become real content.
struct WorkflowRunPanes<Canvas: View, Inspector: View, Activity: View>: View {
    let isGraph: Bool
    var isLoading = false
    var showsInspector = true
    var canvasChromeHeight: CGFloat = 0
    var presentation: WorkflowRunPaneSizing = .default
    @State private var splitSnapshot = WorkflowRunSplitSnapshot()
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let inspector: () -> Inspector
    @ViewBuilder let activity: () -> Activity

    var body: some View {
        Group {
            if isGraph {
                WorkflowPaneViewport {
                    HSplitView {
                        canvas()
.frame(minWidth: WorkflowInspectorWidth.canvasMinimumWidth, maxWidth: .infinity,
                                       minHeight: 0, maxHeight: .infinity)
.clipped()
                        if showsInspector { sidebar }
                    }
                }
            } else {
                WorkflowPaneViewport { HSplitView { activity(); if showsInspector { sidebar } } }
            }
        }
        .onChange(of: showsInspector) { _, visible in
            splitSnapshot.updateVisibility(visible)
        }
    }

    private var sidebar: some View {
        inspector()
.frame(minWidth: HfRadius.Metrics.zero, maxWidth: .infinity, minHeight: HfRadius.Metrics.zero, maxHeight: .infinity)
.clipped()
            .frame(minWidth: WorkflowRunLayout.inspectorMinimum, idealWidth: WorkflowRunLayout.inspectorIdeal(for: presentation),
                          maxWidth: WorkflowRunLayout.inspectorMaximum)
        .background(WorkflowRunSplitPosition(isLoading: isLoading, isGraph: isGraph, presentation: presentation, snapshot: splitSnapshot))
    }
}

#if DEBUG
#Preview {
    WorkflowRunPanes(isGraph: true) { Color.cardFill.opacity(0) } inspector: { Color.neutralFill } activity: { Color.cardFill.opacity(0) }
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.workflowPreviewHeight)
}
#endif
