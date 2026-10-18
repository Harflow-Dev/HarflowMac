import AppKit
import HfUI
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
            let selectionBounds = bounds.insetBy(dx: HfRadius.Metrics.sidebarRowInsetHorizontal,
                                                dy: HfRadius.Metrics.zero)
            NSBezierPath(roundedRect: selectionBounds, xRadius: HfRadius.row, yRadius: HfRadius.row).fill()
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
        .frame(width: HfRadius.Metrics.sidebarPreviewWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Native selection painter - dark") {
    SidebarView(SidebarViewModelMock(selection: .task("def456")))
        .frame(width: HfRadius.Metrics.sidebarPreviewWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}
#endif
