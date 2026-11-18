import HfUI
import SwiftUI

// MARK: - WorkflowBuilderWorkspace

/// The standalone row spans the workspace; the activity replaces the node inspector below it.
/// Measurements belong to this detail viewport, never to the enclosing window or sidebar: the local hosting
/// boundary keeps the floating sidebar's safe area from reaching the canvas's AppKit scroll view a second time.
struct WorkflowBuilderWorkspace<Standalone: View, Canvas: View, Activity: View>: View {
    let standalone: Standalone
    let canvas: Canvas
    let activity: Activity

    init(@ViewBuilder standalone: () -> Standalone, @ViewBuilder canvas: () -> Canvas,
         @ViewBuilder activity: () -> Activity) {
        self.standalone = standalone()
        self.canvas = canvas()
        self.activity = activity()
    }

    var body: some View {
        WorkflowPaneViewport {
            VStack(spacing: 0) {
                standalone
                GeometryReader { viewport in
                    let widths = WorkflowBuilderLayout.widths(viewport: viewport.size.width)
                    HStack(spacing: 0) {
                        canvas
                            .frame(width: widths.canvas, height: max(0, viewport.size.height))
                            .clipped()
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Workflow canvas")
                            .accessibilityIdentifier("workflow-builder-canvas")
                        Rectangle()
                            .fill(Color.hairline)
                            .frame(width: widths.divider)
                            .accessibilityHidden(true)
                        activity
                            .frame(width: widths.activity, height: max(0, viewport.size.height))
                            .clipped()
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Workflow builder activity")
                            .accessibilityIdentifier("workflow-builder-activity")
                    }
                    .frame(width: max(0, viewport.size.width), height: max(0, viewport.size.height))
                    .clipped()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflow-builder-workspace")
        }
    }
}

#if DEBUG
#Preview("Builder workspace") {
    WorkflowBuilderWorkspace {
        Text("Standalone").frame(maxWidth: .infinity).padding()
    } canvas: {
        Color.inspectorFill.overlay(Text("Workflow canvas"))
    } activity: {
        Text("Workflow builder").frame(maxWidth: .infinity, maxHeight: .infinity)
    }.frame(width: 1000, height: 620)
}
#endif
