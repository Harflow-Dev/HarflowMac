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

// MARK: - WorkflowRunSidebarScrollMarker

/// A native marker inside the default run sidebar's scroll document, so its scroll view resolves as
/// `enclosingScrollView` (the pattern of `WorkflowCanvasScrollProbe`).
struct WorkflowRunSidebarScrollMarker: NSViewRepresentable {
    /// True while a selected node's pane covers the sidebar: the native scroll view then leaves the accessibility tree.
    var isHidden = false

    func makeNSView(context _: Context) -> WorkflowRunSidebarScrollProbe {
        let probe = WorkflowRunSidebarScrollProbe()
        probe.hidesScrollViewFromAccessibility = isHidden
        return probe
    }

    func updateNSView(_ view: WorkflowRunSidebarScrollProbe, context _: Context) {
        view.hidesScrollViewFromAccessibility = isHidden
    }
}

final class WorkflowRunSidebarScrollProbe: NSView {
    /// A scroll view this probe hid, with the accessibility values it had before.
    private struct Original { var isElement: Bool; var isHidden: Bool }

    private weak var hiddenScroll: NSScrollView?
    private var original: Original?

    var hidesScrollViewFromAccessibility = false {
        didSet { if oldValue != hidesScrollViewFromAccessibility { applyAccessibility() } }
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAccessibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyAccessibility()
    }

    /// Writes to a scroll view only while hiding it, and restores exactly what it had when it is shown again or replaced.
    private func applyAccessibility() {
        let current = enclosingScrollView
        if let previous = hiddenScroll, previous !== current { restore(previous) }
        guard let scroll = current else { return }
        if hidesScrollViewFromAccessibility {
            if hiddenScroll !== scroll {
                original = Original(isElement: scroll.isAccessibilityElement(), isHidden: scroll.isAccessibilityHidden())
                hiddenScroll = scroll
            }
            scroll.setAccessibilityElement(false)
            scroll.setAccessibilityHidden(true)
        } else if hiddenScroll === scroll {
            restore(scroll)
        }
    }

    private func restore(_ scroll: NSScrollView) {
        if let original {
            scroll.setAccessibilityElement(original.isElement)
            scroll.setAccessibilityHidden(original.isHidden)
        }
        hiddenScroll = nil
        original = nil
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
                    if presentationChanged, snapshot.appliedPresentation?.ownsDefaultInspectorScroll == true {
                        snapshot.defaultInspectorOrigin = defaultScroll?.contentView.bounds.origin
                    }
                    let preferred = snapshot.inspectorWidths[requested] ?? WorkflowRunLayout.inspectorIdeal(for: requested)
                    let width = WorkflowInspectorWidth.clamped(preferred, available: boundsWidth)
                    snapshot.restoring = true
                    split.setPosition(boundsWidth - width - split.dividerThickness, ofDividerAt: 0)
                    if presentationChanged, requested.ownsDefaultInspectorScroll,
                       let origin = snapshot.defaultInspectorOrigin, let defaultScroll {
                        restore(origin, in: defaultScroll, afterLayoutOf: split)
                    }
                    if presentationChanged, requested == .recovery { showRecoveryTop(in: split) }
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
                if requested.ownsDefaultInspectorScroll {
                    // Capture the owner while only the default inspector is visible;
                    // an activity feed may precede it in the native tree when selected.
                    captureDefaultScroll(in: split.arrangedSubviews[1])
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
        moveScroll(to: origin, in: scroll, afterLayoutOf: split)
        snapshot.defaultInspectorOrigin = nil
    }

    /// The shared sidebar scroll view keeps its offset; show the failure sentence and Resume.
    private func showRecoveryTop(in split: NSSplitView) {
        guard let scroll = snapshot.defaultInspectorScroll ?? defaultSidebarScroll(in: split.arrangedSubviews[1]) else { return }
        moveScroll(to: .zero, in: scroll, afterLayoutOf: split)
    }

    private func moveScroll(to origin: NSPoint, in scroll: NSScrollView, afterLayoutOf split: NSSplitView) {
        split.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func captureDefaultScroll(in view: NSView) {
        if let scroll = defaultSidebarScroll(in: view) { snapshot.defaultInspectorScroll = scroll }
    }

    /// The default sidebar's own scroll view: the one enclosing its document marker, never whichever scroll view
    /// comes first in the tree (a mounted selected pane's can precede it).
    private func defaultSidebarScroll(in view: NSView) -> NSScrollView? {
        if let marker = view as? WorkflowRunSidebarScrollProbe { return marker.enclosingScrollView }
        return view.subviews.lazy.compactMap { self.defaultSidebarScroll(in: $0) }.first
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
