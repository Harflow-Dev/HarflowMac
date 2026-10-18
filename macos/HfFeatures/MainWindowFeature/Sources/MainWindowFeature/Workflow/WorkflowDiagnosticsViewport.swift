import HfUI
import SwiftUI

// MARK: - WorkflowDiagnosticsViewport

/// Chooses intrinsic diagnostics when they fit, otherwise keeps them in a capped scroll region.
struct WorkflowDiagnosticsViewport<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content().fixedSize(horizontal: false, vertical: true)
            ScrollView {
                content()
.fixedSize(horizontal: false, vertical: true)
                    // The document probe (§6.4): inside the capped diagnostics region's own
                    // document.
                    .background(ScrollChrome())
            }
            .frame(height: maximumHeight)
        }
        .frame(maxHeight: maximumHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview {
    VStack {
        WorkflowDiagnosticsViewport(maximumHeight: HfRadius.Metrics.workflowDiagnosticsMaximumHeight) {
            Text("Workflow diagnostics").padding()
        }
        Color.cardFill.opacity(0)
    }.frame(width: HfRadius.Metrics.sidebarPreviewHeight, height: HfRadius.Metrics.workflowPreviewHeight)
}

#Preview("Workflow diagnostics viewport - long content scrolls - dark") {
    VStack {
        WorkflowDiagnosticsViewport(maximumHeight: HfRadius.Metrics.workflowDiagnosticsMaximumHeight) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                ForEach(0 ..< 20, id: \.self) { index in
                    Text("Diagnostic line \(index)").padding(.vertical, HfRadius.Metrics.spacing2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Color.cardFill.opacity(0)
    }
    .frame(width: HfRadius.Metrics.sidebarPreviewHeight, height: HfRadius.Metrics.workflowPreviewHeight)
    .preferredColorScheme(.dark)
}

#Preview("Workflow diagnostics viewport - long content scrolls - light") {
    VStack {
        WorkflowDiagnosticsViewport(maximumHeight: HfRadius.Metrics.workflowDiagnosticsMaximumHeight) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                ForEach(0 ..< 20, id: \.self) { index in
                    Text("Diagnostic line \(index)").padding(.vertical, HfRadius.Metrics.spacing2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Color.cardFill.opacity(0)
    }
    .frame(width: HfRadius.Metrics.sidebarPreviewHeight, height: HfRadius.Metrics.workflowPreviewHeight)
    .preferredColorScheme(.light)
}
#endif
