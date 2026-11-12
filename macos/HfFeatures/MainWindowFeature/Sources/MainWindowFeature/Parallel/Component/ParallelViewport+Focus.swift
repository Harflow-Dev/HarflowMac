import AppKit
import Combine

// MARK: - Lane reveal on focus

extension ParallelScrollObservationView {
    /// Starts watching the window's first responder for a horizontal lane row.
    func observeFocus(in scroll: NSScrollView) {
        guard axis == .horizontal, !usesNativeIdentity, let window = scroll.window else { return }
        focusedLaneIndex = nil
        // The delivered value is ignored: the first responder is read fresh when the change is handled.
        window.publisher(for: \.firstResponder, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.firstResponderChanged() }
            .store(in: &subscriptions)
    }

    /// Keyboard reach of lanes: when focus ENTERS a different lane (a focus-change edge, never a re-render
    /// while focus stays), the row scrolls to show that whole lane. A reveal is explicit navigation, so it
    /// cancels pending horizontal restoration first. Residency stays geometry-driven: only the resulting
    /// scroll can bring the next lane (and its controls) into being.
    private func firstResponderChanged() {
        guard axis == .horizontal, !usesNativeIdentity, !isTornDown, let scroll = observedScrollView,
              let document = scroll.documentView, let window = scroll.window else { return }
        guard let responder = window.firstResponder as? NSView, responder !== document, responder.isDescendant(of: document),
              stride > 0, !ids.isEmpty else {
            focusedLaneIndex = nil
            return
        }
        let frame = document.convert(responder.bounds, from: responder)
        let index = min(max(0, Int((frame.midX / stride).rounded(.down))), ids.count - 1)
        guard index != focusedLaneIndex else { return }
        focusedLaneIndex = index
        revealLane(index, scroll: scroll, document: document)
    }

    private func revealLane(_ index: Int, scroll: NSScrollView, document: NSView) {
        let length = document.bounds.width
        let visible = scroll.documentVisibleRect
        guard visible.width > 0, abs(length - CGFloat(ids.count) * stride) < 2 else { return }
        let laneMin = CGFloat(index) * stride
        let laneMax = laneMin + stride - ParallelLayout.dividerWidth
        var target = visible.minX
        if laneMin < visible.minX - 0.5 {
            target = laneMin
        } else if laneMax > visible.maxX + 0.5 {
            // Show the lane wholly, plus its separator and one point of the following lane: that lane then
            // intersects the viewport, becomes resident and builds its controls, so Tab can continue.
            let trailing = index + 1 < ids.count ? ParallelLayout.dividerWidth + 1 : 0
            target = min(laneMin, laneMax + trailing - visible.width)
        }
        target = min(max(0, target), max(0, length - visible.width))
        guard abs(target - visible.minX) > 0.5 else { return }
        cancelHorizontalMovement()
        applyRestorationTarget(target, scroll: scroll, document: document, geometry: (length, visible.width, visible))
        report()
    }
}
