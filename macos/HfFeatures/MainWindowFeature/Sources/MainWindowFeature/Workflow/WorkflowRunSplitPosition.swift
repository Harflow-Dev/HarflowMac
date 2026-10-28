import AppKit
import HfUI
import SwiftUI

// MARK: - WorkflowRunSplitPosition

/// AppKit may re-propose a pane's intrinsic width when skeleton content is replaced.
/// Retain the last laid-out dividers across that one transition, including user resizing.
struct WorkflowRunSplitPosition: NSViewRepresentable {
    let isLoading: Bool
    let presentation: WorkflowRunPaneSizing
    let snapshot: WorkflowRunSplitSnapshot

    func makeNSView(context _: Context) -> WorkflowRunSplitProbe {
        WorkflowRunSplitProbe(snapshot: snapshot)
    }

    func updateNSView(_ view: WorkflowRunSplitProbe, context _: Context) {
        snapshot.update(isLoading: isLoading, presentation: presentation)
        view.needsLayout = true
    }
}

// MARK: - WorkflowRunSplitSnapshot

/// Owned by the pane shell because SwiftUI can recreate a pane's platform background view.
@MainActor
final class WorkflowRunSplitSnapshot {
    var isLoading: Bool?
    var restoring = false
    var loadingTransition = false
    var requestedPresentation: WorkflowRunPaneSizing = .default
    var appliedPresentation: WorkflowRunPaneSizing?
    var inspectorWidths: [WorkflowRunPaneSizing: CGFloat] = [:]
    var lastInspectorIdentity: ObjectIdentifier?
    var lastInspectorBoundsWidth: CGFloat?
    var lastObservedInspectorWidth: CGFloat?
    var canvasHeight: CGFloat?
    var defaultInspectorOrigin: NSPoint?
    weak var defaultInspectorScroll: NSScrollView?
    weak var inspectorSplit: NSSplitView?
    weak var canvasSplit: NSSplitView?

    func update(isLoading: Bool, presentation: WorkflowRunPaneSizing) {
        if let previous = self.isLoading, previous != isLoading { loadingTransition = true }
        self.isLoading = isLoading
        requestedPresentation = presentation
    }
}

// MARK: - WorkflowRunSplitProbe

final class WorkflowRunSplitProbe: NSView {
    private let snapshot: WorkflowRunSplitSnapshot

    init(snapshot: WorkflowRunSplitSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard !snapshot.restoring else { return }
        for split in ancestorSplits() where split.arrangedSubviews.count == 2 {
            if split.isVertical {
                snapshot.inspectorSplit = split
                let identity = ObjectIdentifier(split)
                let boundsWidth = split.bounds.width
                let requested = snapshot.requestedPresentation
                let availableForInspector = boundsWidth - WorkflowInspectorWidth.canvasMinimumWidth - split.dividerThickness
                let canInitialize = availableForInspector >= WorkflowRunLayout.inspectorMinimum
                let identityChanged = snapshot.lastInspectorIdentity != identity
                let boundsChanged = snapshot.lastInspectorBoundsWidth != boundsWidth
                let presentationChanged = snapshot.appliedPresentation != requested
                let didApply = canInitialize && (presentationChanged || identityChanged || boundsChanged
                    || (snapshot.loadingTransition && snapshot.appliedPresentation == requested))

                if didApply {
                    let defaultScroll = snapshot.defaultInspectorScroll
                    if presentationChanged, snapshot.appliedPresentation == .default {
                        snapshot.defaultInspectorOrigin = defaultScroll?.contentView.bounds.origin
                    }
                    let preferred = snapshot.inspectorWidths[requested] ?? WorkflowRunLayout.inspectorIdeal(for: requested)
                    let width = WorkflowInspectorWidth.clamped(preferred, available: boundsWidth)
                    snapshot.restoring = true
                    split.setPosition(boundsWidth - width - split.dividerThickness, ofDividerAt: 0)
                    if presentationChanged, requested == .default,
                       let origin = snapshot.defaultInspectorOrigin, let defaultScroll {
                        restore(origin, in: defaultScroll, afterLayoutOf: split)
                    }
                    snapshot.restoring = false
                    snapshot.appliedPresentation = requested
                    snapshot.lastObservedInspectorWidth = split.arrangedSubviews[1].frame.width
                }

                let applied = snapshot.appliedPresentation
                let width = split.arrangedSubviews[1].frame.width
                let widthChanged = snapshot.lastObservedInspectorWidth.map { abs(width - $0) > 0.001 } ?? false
                let safeToCapture = applied == requested && !identityChanged && !boundsChanged
                    && canInitialize && !didApply && !snapshot.loadingTransition && !snapshot.restoring
                if safeToCapture, widthChanged, let applied {
                    snapshot.inspectorWidths[applied] = width
                }
                snapshot.lastObservedInspectorWidth = width
                snapshot.lastInspectorIdentity = identity
                snapshot.lastInspectorBoundsWidth = boundsWidth
                if requested == .default {
                    // Capture the owner while only the default inspector is visible;
                    // an activity feed may precede it in the native tree when selected.
                    snapshot.defaultInspectorScroll = firstScrollView(in: split.arrangedSubviews[1])
                }
            } else {
                if snapshot.loadingTransition, snapshot.canvasSplit === split, let canvasHeight = snapshot.canvasHeight {
                    snapshot.restoring = true
                    split.setPosition(canvasHeight, ofDividerAt: 0)
                    snapshot.restoring = false
                }
                snapshot.canvasSplit = split
                snapshot.canvasHeight = split.arrangedSubviews[0].frame.height
            }
        }
        snapshot.loadingTransition = false
    }

    private func restore(_ origin: NSPoint, in scroll: NSScrollView, afterLayoutOf split: NSSplitView) {
        // The hidden inspector can clamp its origin while it reflows at the activity width.
        // Restore only after its saved divider width and document layout apply again.
        split.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        snapshot.defaultInspectorOrigin = nil
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func ancestorSplits() -> [NSSplitView] {
        var result: [NSSplitView] = []
        var view = superview
        while let ancestor = view {
            if let split = ancestor as? NSSplitView {
                result.append(split)
                // The next split is either the graph's horizontal split or the app's navigation split.
                var parent = split.superview
                while let candidate = parent {
                    if let next = candidate as? NSSplitView {
                        if !next.isVertical { result.append(next) }
                        return result
                    }
                    parent = candidate.superview
                }
                return result
            }
            view = ancestor.superview
        }
        return result
    }
}

#if DEBUG
#Preview("Workflow run split - light") {
    WorkflowRunPanes(isGraph: true) { Color.inspectorFill } inspector: { Color.cardFill } activity: { Color.cardFill }
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow run split - dark") {
    WorkflowRunPanes(isGraph: true) { Color.inspectorFill } inspector: { Color.cardFill } activity: { Color.cardFill }
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.dark)
}
#endif
