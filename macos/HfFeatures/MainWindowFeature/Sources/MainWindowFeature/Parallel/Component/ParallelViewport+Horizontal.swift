import AppKit

// MARK: - Horizontal offsets inside content insets

extension ParallelScrollObservationView {
    /// The content insets a horizontal lane row keeps on its scroll view: the detail column's safe area where a floating
    /// sidebar overlaps it, so the document starts at the sidebar's edge. Offsets and viewport widths are measured
    /// inside them: offset 0 is the first lane at the leading inset. Zero for a vertical axis or an uninset scroll view.
    func horizontalInsets(of scroll: NSScrollView) -> (leading: CGFloat, trailing: CGFloat) {
        guard axis == .horizontal else { return (0, 0) }
        return (max(0, scroll.contentInsets.left), max(0, scroll.contentInsets.right))
    }

    /// `target` is a logical offset and `geometry.viewport` a logical width (inside the insets); `geometry.visible` is the
    /// raw visible rect.
    func applyRestorationTarget(_ target: CGFloat, scroll: NSScrollView, document: NSView,
                                geometry: (length: CGFloat, viewport: CGFloat, visible: CGRect)) {
        let (length, viewport, visible) = geometry
        diagnose("apply target=\(target) visible=\(visible.minY) height=\(length) viewport=\(viewport) before")
        pendingOffset = nil
        let clamped = min(max(0, target), max(0, length - viewport))
        var point = scroll.contentView.bounds.origin
        if axis == .horizontal {
            point.x = clamped - horizontalInsets(of: scroll).leading
        } else {
            point.y = document.isFlipped ? clamped : max(0, document.bounds.maxY - viewport - clamped)
        }
        if abs((axis == .horizontal ? point.x : point.y) - (axis == .horizontal ? visible.minX : visible.minY)) > 0.5 {
            applyingRestoration = true
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
            applyingRestoration = false
        }
        diagnose("apply after target=\(target)")
    }

    func clampHorizontalOffset(scroll: NSScrollView, document: NSView, length: CGFloat, viewport: CGFloat) {
        guard axis == .horizontal, !liveUserScroll, !applyingRestoration, viewport > 0,
              scroll.contentView.bounds.minX + horizontalInsets(of: scroll).leading > max(0, length - viewport) + 0.5 else { return }
        applyRestorationTarget(max(0, length - viewport), scroll: scroll, document: document,
                               geometry: (length, viewport, scroll.documentVisibleRect))
    }

    /// A changed leading inset (a floating sidebar showing or hiding) moves the raw clip origin of the same logical
    /// position, so the reader's position is re-applied.
    func noteLeadingInset(_ leading: CGFloat) {
        guard axis == .horizontal else { return }
        if let previous = lastLeadingInset, abs(previous - leading) > 0.5, !liveUserScroll, pendingOffset == nil,
           preservedHorizontalOffset == nil { pendingOffset = lastOffset }
        lastLeadingInset = leading
    }
}
