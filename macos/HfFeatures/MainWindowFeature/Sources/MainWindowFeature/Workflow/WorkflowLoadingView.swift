import HfUI
import SwiftUI

// MARK: - WorkflowLoadingView

struct WorkflowLoadingView: View {
    let isRun: Bool
    var body: some View {
        Group {
            if isRun {
                WorkflowRunPanes(isGraph: true) {
                    WorkflowLoadingCanvas()
                } inspector: {
                    WorkflowLoadingInspector(isRun: true)
                } activity: {
                    WorkflowLoadingActivity()
                }
            } else {
                WorkflowInspectorSplit {
                    WorkflowLoadingCanvas()
                } inspector: {
                    WorkflowLoadingInspector(isRun: false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRun ? "Loading workflow run" : "Loading workflow canvas")
    }
}

// MARK: - WorkflowLoadingCanvas

struct WorkflowLoadingCanvas: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, max(0.2, (geometry.size.width - HfRadius.Metrics.workflowNodePreviewInset) / HfRadius.Metrics.workflowLoadingGraphWidth))
            HStack(spacing: HfRadius.Metrics.zero) {
                node(compact: true)
                connector
                node(compact: false)
                connector
                node(compact: false)
                connector
                node(compact: true)
            }
            .frame(width: HfRadius.Metrics.workflowLoadingGraphWidth, height: HfRadius.Metrics.workflowLoadingNodeHeight)
            .scaleEffect(scale)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.clipped()
    }

    private var connector: some View {
        connectorShapes(.skeletonFill).shimmering().mask(connectorShapes(.cardFill))
    }

    private func connectorShapes(_ color: Color) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: HfRadius.Metrics.workflowLoadingConnectorMidpoint))
                path.addLine(to: CGPoint(x: HfRadius.Metrics.workflowLoadingConnectorTip, y: HfRadius.Metrics.workflowLoadingConnectorMidpoint))
                path.move(to: CGPoint(x: HfRadius.Metrics.workflowLoadingConnectorWing, y: HfRadius.Metrics.workflowLoadingConnectorUpperY))
                path.addLine(to: CGPoint(x: HfRadius.Metrics.workflowLoadingConnectorTip, y: HfRadius.Metrics.workflowLoadingConnectorMidpoint))
                path.addLine(to: CGPoint(x: HfRadius.Metrics.workflowLoadingConnectorWing, y: HfRadius.Metrics.workflowLoadingConnectorLowerY))
            }.stroke(color, style: StrokeStyle(lineWidth: HfRadius.Metrics.workflowConnectionHighlightedLineWidth, lineCap: .round, lineJoin: .round))
            Circle()
.fill(color)
                .frame(width: HfRadius.Metrics.spacing5, height: HfRadius.Metrics.spacing5)
                .position(x: 0, y: HfRadius.Metrics.workflowLoadingConnectorMidpoint)
            Circle()
.fill(color)
                .frame(width: HfRadius.Metrics.spacing5, height: HfRadius.Metrics.spacing5)
                .position(x: HfRadius.Metrics.workflowNodePreviewInset, y: HfRadius.Metrics.workflowLoadingConnectorMidpoint)
        }
.frame(width: HfRadius.Metrics.workflowNodePreviewInset, height: HfRadius.Metrics.workflowLoadingNodeHeight)
    }

    private func node(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            SkeletonBlock(width: compact ? HfRadius.Metrics.spacing24 : HfRadius.Metrics.workflowLoadingTitleWidth, height: HfRadius.Metrics.spacing12)
            if !compact { SkeletonBlock(width: HfRadius.Metrics.workflowLoadingMetaWidth, height: HfRadius.Metrics.spacing8) }
        }
        .padding(HfRadius.Metrics.spacing14)
        .frame(width: compact ? HfRadius.Metrics.workflowLoadingCompactNodeSize : HfRadius.Metrics.workflowLoadingNodeWidth,
               height: compact ? HfRadius.Metrics.workflowLoadingCompactNodeSize : HfRadius.Metrics.workflowLoadingNodeHeight)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder))
    }
}

// MARK: - WorkflowLoadingInspector

struct WorkflowLoadingInspector: View {
    let isRun: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
            SkeletonBlock(width: HfRadius.Metrics.taskSkeletonStatusWidth, height: HfRadius.Metrics.spacing16)
            SkeletonRows(count: isRun ? 3 : 5)
            if !isRun { SkeletonBlock(height: HfRadius.Metrics.recoveryEditorMaximumHeight) }
            Spacer(minLength: 0)
        }
.padding(HfRadius.Metrics.spacing16)
.background(Color.cardFill)
    }
}

// MARK: - WorkflowLoadingActivity

struct WorkflowLoadingActivity: View {
    var body: some View {
        GeometryReader { viewport in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: HfRadius.Metrics.zero) {
                    ForEach(0 ..< 2) { _ in
                        VStack(alignment: .leading, spacing: HfRadius.Metrics.taskSkeletonFeedSpacing) {
                            SkeletonBlock(width: HfRadius.Metrics.sidebarSearchMinimumWidth, height: HfRadius.Metrics.spacing16)
                            SkeletonBlock(height: HfRadius.Metrics.workflowLoadingSpacer)
                            SkeletonRows(count: 3)
                            Spacer(minLength: 0)
                        }
                        .padding(HfRadius.Metrics.spacing16)
                        .frame(width: ParallelLayout.columnWidth(memberCount: 2, availableWidth: viewport.size.width),
                               height: viewport.size.height)
                        Divider()
                    }
                }
                // The document probe (§6.4): inside the loading activity lane's own document.
                .background(ScrollChrome())
            }
        }
    }
}

#if DEBUG
#Preview("Workflow canvas loading - light") {
    WorkflowLoadingView(isRun: false).frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.light)
}

#Preview("Workflow canvas loading - dark") {
    WorkflowLoadingView(isRun: false).frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.dark)
}

#Preview("Workflow run loading - light") {
    WorkflowLoadingView(isRun: true).frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.light)
}

#Preview("Workflow run loading - dark") {
    WorkflowLoadingView(isRun: true).frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.dark)
}
#endif
