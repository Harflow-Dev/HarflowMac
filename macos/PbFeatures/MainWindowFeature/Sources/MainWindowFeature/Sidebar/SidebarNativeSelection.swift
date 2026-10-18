import AppKit
import PbUI
import SwiftUI

// MARK: - SidebarNativeSelection

/// Keeps AppKit selection semantics while painting the sidebar's palette surface.
final class SidebarNativeSelection: NSTableRowView {
    // Regular painting routes AppKit through drawSelection without a blue source-list backing.
    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .regular }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in _: NSRect) {
        guard isSelected else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor(Color.selectedRow).setFill()
            let selectionBounds = bounds.insetBy(dx: PbRadius.Metrics.sidebarRowInsetHorizontal,
                                                dy: PbRadius.Metrics.zero)
            NSBezierPath(roundedRect: selectionBounds, xRadius: PbRadius.row, yRadius: PbRadius.row).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

#if DEBUG
#Preview("Native selection painter - light") {
    SidebarView(SidebarViewModelMock(selection: .task("def456")))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Native selection painter - dark") {
    SidebarView(SidebarViewModelMock(selection: .task("def456")))
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}
#endif
