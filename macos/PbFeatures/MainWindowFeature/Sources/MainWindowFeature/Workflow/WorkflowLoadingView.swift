import PbUI
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
            let scale = min(1, max(0.2, (geometry.size.width - PbRadius.Metrics.workflowNodePreviewInset) / PbRadius.Metrics.workflowLoadingGraphWidth))
            HStack(spacing: PbRadius.Metrics.zero) {
                node(compact: true)
                connector
                node(compact: false)
                connector
                node(compact: false)
                connector
                node(compact: true)
            }
            .frame(width: PbRadius.Metrics.workflowLoadingGraphWidth, height: PbRadius.Metrics.workflowLoadingNodeHeight)
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
                path.move(to: CGPoint(x: 0, y: PbRadius.Metrics.workflowLoadingConnectorMidpoint))
                path.addLine(to: CGPoint(x: PbRadius.Metrics.workflowLoadingConnectorTip, y: PbRadius.Metrics.workflowLoadingConnectorMidpoint))
                path.move(to: CGPoint(x: PbRadius.Metrics.workflowLoadingConnectorWing, y: PbRadius.Metrics.workflowLoadingConnectorUpperY))
                path.addLine(to: CGPoint(x: PbRadius.Metrics.workflowLoadingConnectorTip, y: PbRadius.Metrics.workflowLoadingConnectorMidpoint))
                path.addLine(to: CGPoint(x: PbRadius.Metrics.workflowLoadingConnectorWing, y: PbRadius.Metrics.workflowLoadingConnectorLowerY))
            }.stroke(color, style: StrokeStyle(lineWidth: PbRadius.Metrics.workflowConnectionHighlightedLineWidth, lineCap: .round, lineJoin: .round))
            Circle()
.fill(color)
                .frame(width: PbRadius.Metrics.spacing5, height: PbRadius.Metrics.spacing5)
                .position(x: 0, y: PbRadius.Metrics.workflowLoadingConnectorMidpoint)
            Circle()
.fill(color)
                .frame(width: PbRadius.Metrics.spacing5, height: PbRadius.Metrics.spacing5)
                .position(x: PbRadius.Metrics.workflowNodePreviewInset, y: PbRadius.Metrics.workflowLoadingConnectorMidpoint)
        }
.frame(width: PbRadius.Metrics.workflowNodePreviewInset, height: PbRadius.Metrics.workflowLoadingNodeHeight)
    }

    private func node(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            SkeletonBlock(width: compact ? PbRadius.Metrics.spacing24 : PbRadius.Metrics.workflowLoadingTitleWidth, height: PbRadius.Metrics.spacing12)
            if !compact { SkeletonBlock(width: PbRadius.Metrics.workflowLoadingMetaWidth, height: PbRadius.Metrics.spacing8) }
        }
        .padding(PbRadius.Metrics.spacing14)
        .frame(width: compact ? PbRadius.Metrics.workflowLoadingCompactNodeSize : PbRadius.Metrics.workflowLoadingNodeWidth,
               height: compact ? PbRadius.Metrics.workflowLoadingCompactNodeSize : PbRadius.Metrics.workflowLoadingNodeHeight)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(Color.cardBorder))
    }
}

// MARK: - WorkflowLoadingInspector

struct WorkflowLoadingInspector: View {
    let isRun: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
            SkeletonBlock(width: PbRadius.Metrics.taskSkeletonStatusWidth, height: PbRadius.Metrics.spacing16)
            SkeletonRows(count: isRun ? 3 : 5)
            if !isRun { SkeletonBlock(height: PbRadius.Metrics.recoveryEditorMaximumHeight) }
            Spacer(minLength: 0)
        }
.padding(PbRadius.Metrics.spacing16)
.background(Color.cardFill)
    }
}

// MARK: - WorkflowLoadingActivity

struct WorkflowLoadingActivity: View {
    var body: some View {
        GeometryReader { viewport in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: PbRadius.Metrics.zero) {
                    ForEach(0 ..< 2) { _ in
                        VStack(alignment: .leading, spacing: PbRadius.Metrics.taskSkeletonFeedSpacing) {
                            SkeletonBlock(width: PbRadius.Metrics.sidebarSearchMinimumWidth, height: PbRadius.Metrics.spacing16)
                            SkeletonBlock(height: PbRadius.Metrics.workflowLoadingSpacer)
                            SkeletonRows(count: 3)
                            Spacer(minLength: 0)
                        }
                        .padding(PbRadius.Metrics.spacing16)
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
    WorkflowLoadingView(isRun: false).frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.light)
}

#Preview("Workflow canvas loading - dark") {
    WorkflowLoadingView(isRun: false).frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.dark)
}

#Preview("Workflow run loading - light") {
    WorkflowLoadingView(isRun: true).frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.light)
}

#Preview("Workflow run loading - dark") {
    WorkflowLoadingView(isRun: true).frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight).preferredColorScheme(.dark)
}
#endif
