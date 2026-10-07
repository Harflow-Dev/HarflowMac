import AppKit
import SwiftUI

// MARK: - WorkflowPaneViewport

/// Gives native split views a local hosting boundary instead of the navigation window's safe area.
struct WorkflowPaneViewport<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<WorkflowPaneViewportContent<Content>> {
        let host = NSHostingView(rootView: WorkflowPaneViewportContent(content: content(), environment: context.environment))
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: NSHostingView<WorkflowPaneViewportContent<Content>>, context: Context) {
        host.rootView = WorkflowPaneViewportContent(content: content(), environment: context.environment)
    }
}

// MARK: - WorkflowPaneViewportContent

/// Forwards presentation bindings, accessibility preferences and appearance across the local host.
struct WorkflowPaneViewportContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues

    var body: some View {
        content.environment(\.self, environment)
    }
}
