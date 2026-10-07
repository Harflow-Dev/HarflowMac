import AppKit
import SwiftUI

// MARK: - WorkflowInspectorWidth

enum WorkflowInspectorWidth {
    static let initial: CGFloat = 320
    static func clamped(_ requested: CGFloat, available: CGFloat) -> CGFloat {
        min(max(220, requested), min(500, max(220, available - 401)))
    }
}

// MARK: - WorkflowInspectorSplit

/// A bounded native split: SwiftUI's HSplitView can attach to the navigation host's
/// whole window instead of its detail pane, hiding the left graph under the sidebar.
struct WorkflowInspectorSplit<Content: View, Inspector: View>: NSViewRepresentable {
    let content: Content
    let inspector: Inspector

    init(@ViewBuilder content: () -> Content, @ViewBuilder inspector: () -> Inspector) {
        self.content = content()
        self.inspector = inspector()
    }

    func makeNSView(context: Context) -> WorkflowInspectorNativeSplit {
        WorkflowInspectorNativeSplit(content: AnyView(content.environment(\.self, context.environment)),
                                     inspector: AnyView(inspector.environment(\.self, context.environment)))
    }

    func updateNSView(_ split: WorkflowInspectorNativeSplit, context: Context) {
        // Each native hosting root needs the parent environment, including routing,
        // file-link actions, app storage defaults, and accessibility preferences.
        split.contentHost.rootView = AnyView(content.environment(\.self, context.environment))
        split.inspectorHost.rootView = AnyView(inspector.environment(\.self, context.environment))
    }
}

// MARK: - WorkflowInspectorNativeSplit

final class WorkflowInspectorNativeSplit: NSSplitView, NSSplitViewDelegate {
    let contentHost: NSHostingView<AnyView>
    let inspectorHost: NSHostingView<AnyView>
    private var inspectorWidth = WorkflowInspectorWidth.initial

    init(content: AnyView, inspector: AnyView) {
        self.contentHost = NSHostingView(rootView: content)
        self.inspectorHost = NSHostingView(rootView: inspector)
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        contentHost.sizingOptions = []
        inspectorHost.sizingOptions = []
        addArrangedSubview(contentHost)
        addArrangedSubview(inspectorHost)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func splitView(_: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
        guard bounds.width > 0 else { return }
        let width = WorkflowInspectorWidth.clamped(inspectorWidth, available: bounds.width)
        let contentWidth = max(0, bounds.width - width - dividerThickness)
        contentHost.frame = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        inspectorHost.frame = CGRect(x: contentWidth + dividerThickness, y: 0, width: width, height: bounds.height)
        inspectorWidth = width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate _: CGFloat, ofSubviewAt _: Int) -> CGFloat { 400 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate _: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        max(400, splitView.bounds.width - 220 - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        let width = WorkflowInspectorWidth.clamped(bounds.width - proposedPosition - dividerThickness, available: bounds.width)
        return bounds.width - width - dividerThickness
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === self, inspectorHost.frame.width > 0 else { return }
        inspectorWidth = inspectorHost.frame.width
    }
}

#if DEBUG
#Preview {
    WorkflowInspectorSplit {
        Color(nsColor: .windowBackgroundColor)
    } inspector: {
        Text("Inspector").frame(maxWidth: .infinity, maxHeight: .infinity)
    }.frame(width: 1000, height: 600)
}
#endif
