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

struct WorkflowInspectorSplit<Content: View, Inspector: View>: View {
    let content: Content
    let inspector: Inspector

    init(@ViewBuilder content: () -> Content, @ViewBuilder inspector: () -> Inspector) {
        self.content = content()
        self.inspector = inspector()
    }

    var body: some View {
        HSplitView {
            content.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            inspector.frame(minWidth: 220, idealWidth: WorkflowInspectorWidth.initial, maxWidth: 500)
                .background(WorkflowSplitInitialSize())
        }
    }
}

// MARK: - WorkflowSplitInitialSize

private struct WorkflowSplitInitialSize: NSViewRepresentable {
    func makeNSView(context _: Context) -> WorkflowSplitSizeProbe { WorkflowSplitSizeProbe() }
    func updateNSView(_: WorkflowSplitSizeProbe, context _: Context) {}
}

// MARK: - WorkflowSplitSizeProbe

private final class WorkflowSplitSizeProbe: NSView {
    private weak var initializedSplit: NSSplitView?
    private var sizingPending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInitialSize()
    }

    override func layout() {
        super.layout()
        scheduleInitialSize()
    }

    private func scheduleInitialSize() {
        guard window != nil, !sizingPending else { return }
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 {
                guard initializedSplit !== split, split.bounds.width > 0 else { return }
                sizingPending = true
                DispatchQueue.main.async { [weak self, weak split] in
                    guard let self else { return }
                    sizingPending = false
                    guard window != nil, let split, split.bounds.width > 0, initializedSplit !== split else { return }
                    let width = WorkflowInspectorWidth.clamped(WorkflowInspectorWidth.initial, available: split.bounds.width)
                    split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
                    initializedSplit = split
                }
                return
            }
            ancestor = view.superview
        }
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
