import SwiftUI

// MARK: - WorkflowScreenLayout

/// Keeps the header at the top when failed content has only an intrinsic height.
struct WorkflowScreenLayout<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header().fixedSize(horizontal: false, vertical: true)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
