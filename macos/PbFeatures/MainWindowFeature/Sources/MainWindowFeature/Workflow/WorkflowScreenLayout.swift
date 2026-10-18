import SwiftUI

// MARK: - WorkflowScreenLayout

/// Keeps the header visible and lets panes use the window's remaining viewport.
/// Split panes and long run details must not enlarge the navigation host's minimum height.
struct WorkflowScreenLayout<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        // The header must share the viewport boundary: its vertically fixed wrapping
        // otherwise becomes a native navigation minimum at narrow window widths.
        GeometryReader { screen in
        VStack(spacing: 0) {
            header().fixedSize(horizontal: false, vertical: true)
            GeometryReader { viewport in
                content()
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                    .clipped()
            }
        }.frame(width: screen.size.width, height: screen.size.height, alignment: .top)
        }
    }
}

#if DEBUG
#Preview {
    WorkflowScreenLayout {
        Text("Workflow header").frame(maxWidth: .infinity).padding()
    } content: {
        ContentUnavailableView("Workflow could not be loaded", systemImage: "exclamationmark.triangle")
    }.frame(width: 1000, height: 1000)
}
#endif
