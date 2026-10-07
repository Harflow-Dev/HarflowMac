import SwiftUI

// MARK: - WorkflowDiagnosticsViewport

/// Chooses intrinsic diagnostics when they fit, otherwise keeps them in a capped scroll region.
struct WorkflowDiagnosticsViewport<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content().fixedSize(horizontal: false, vertical: true)
            ScrollView { content().fixedSize(horizontal: false, vertical: true) }
                .frame(height: maximumHeight)
        }
        .frame(maxHeight: maximumHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview {
    VStack {
        WorkflowDiagnosticsViewport(maximumHeight: 180) {
            Text("Workflow diagnostics").padding()
        }
        Color.clear
    }.frame(width: 600, height: 700)
}
#endif
