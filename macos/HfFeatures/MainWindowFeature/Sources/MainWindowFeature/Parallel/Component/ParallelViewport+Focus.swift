import AppKit
import Combine

// MARK: - ParallelFocusReveal

/// Reveal bookkeeping of one horizontal lane row.
struct ParallelFocusReveal {
    /// The lane keyboard focus was last moved into and handled (revealed, or already whole): a reveal fires only when
    /// keyboard focus enters a different lane. Set only once the lane was handled, never while its reveal is pending.
    var lane: Int?
    /// The lane was entered by the pointer only: nothing scrolled, so a keyboard move to a control that is off-screen in
    /// that same lane still reveals it (it is skipped only when the lane is already whole).
    var lanePointerOnly = false
    /// A lane whose reveal waits for the row's layout, retried when the document's frame changes.
    var pending: Int?
    var retry: AnyCancellable?
}

// MARK: - Lane reveal on keyboard focus

extension ParallelScrollObservationView {
    /// The type of the event being processed when the first responder changes. Tests replace it to simulate a key or a
    /// mouse event, since the harness cannot deliver a real Tab.
    static var focusEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

    /// Starts watching the window's first responder for a horizontal lane row.
    func observeFocus(in scroll: NSScrollView) {
        guard axis == .horizontal, !usesNativeIdentity, let window = scroll.window else { return }
        focusReveal = ParallelFocusReveal()
        // The delivered value is ignored: the first responder is read fresh when the change is handled. The event
        // type is read synchronously, while the responder change is still inside its originating event.
        // No `receive(on:)` here: `firstResponder` changes only on main and the event type must be read synchronously (macos/AGENTS.md:75).
        window.publisher(for: \.firstResponder, options: [.new])
            .sink { [weak self] _ in
                let isKeyboard = Self.focusEventType() == .keyDown
                DispatchQueue.main.async { self?.firstResponderChanged(isKeyboard: isKeyboard) }
            }
            .store(in: &subscriptions)
    }

    /// Keyboard reach of lanes: when KEYBOARD focus (Tab, Shift-Tab) ENTERS a different lane, the row scrolls to show
    /// that whole lane plus its separator and one point of the neighbouring lane in the scroll direction, so that
    /// neighbour becomes resident and the next Tab or Shift-Tab can continue. A mouse click never scrolls the row
    /// under the pointer, and focus that stays in a lane never re-triggers a reveal. A reveal is explicit navigation,
    /// so it cancels pending horizontal restoration first. Residency stays geometry-driven.
    private func firstResponderChanged(isKeyboard: Bool) {
        guard axis == .horizontal, !usesNativeIdentity, !isTornDown, let scroll = observedScrollView,
              let document = scroll.documentView, let index = focusedLane(scroll: scroll, document: document) else {
            focusReveal = ParallelFocusReveal()
            return
        }
        // Pointer focus is recorded without scrolling. A later keyboard move within that lane reveals it only if the lane is not already whole.
        guard isKeyboard else {
            focusReveal = ParallelFocusReveal(lane: index, lanePointerOnly: true)
            return
        }
        guard index != focusReveal.lane || focusReveal.lanePointerOnly else { return }
        reveal(index, scroll: scroll, document: document)
    }

    /// The lane that holds the window's first responder, if it is inside the row's document.
    private func focusedLane(scroll: NSScrollView, document: NSView) -> Int? {
        guard let responder = scroll.window?.firstResponder as? NSView, responder !== document, responder.isDescendant(of: document),
              stride > 0, !ids.isEmpty else { return nil }
        let frame = document.convert(responder.bounds, from: responder)
        return min(max(0, Int((frame.midX / stride).rounded(.down))), ids.count - 1)
    }

    /// Reveals the lane now, or keeps it pending until the row's layout settles.
    private func reveal(_ index: Int, scroll: NSScrollView, document: NSView) {
        if revealLane(index, scroll: scroll, document: document) {
            focusReveal = ParallelFocusReveal(lane: index)
            return
        }
        focusReveal.pending = index
        guard focusReveal.retry == nil else { return }
        document.postsFrameChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        focusReveal.retry = NotificationCenter.default
.publisher(for: NSView.frameDidChangeNotification, object: document)
            .merge(with: NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scroll))
            .sink { [weak self] _ in DispatchQueue.main.async { self?.retryPendingReveal() } }
    }

    private func retryPendingReveal() {
        guard let pending = focusReveal.pending, !isTornDown, let scroll = observedScrollView, let document = scroll.documentView,
              focusedLane(scroll: scroll, document: document) == pending else {
            focusReveal.pending = nil
            focusReveal.retry = nil
            return
        }
        reveal(pending, scroll: scroll, document: document)
    }

    /// Scrolls the lane into view. False only while the row's layout is not ready for lane geometry.
    private func revealLane(_ index: Int, scroll: NSScrollView, document: NSView) -> Bool {
        let length = document.bounds.width
        let visible = scroll.documentVisibleRect
        guard visible.width > 0, abs(length - CGFloat(ids.count) * stride) < 2 else { return false }
        let laneMin = CGFloat(index) * stride
        let laneMax = laneMin + stride - ParallelLayout.dividerWidth
        // The lane wholly, plus its separator and one point of the neighbouring lane on each side that has one, so
        // that neighbour intersects the viewport, becomes resident and the next Tab or Shift-Tab can continue.
        let peek = ParallelLayout.dividerWidth + 1
        let leftBound = laneMin - (index > 0 ? peek : 0)
        let rightBound = laneMax + (index + 1 < ids.count ? peek : 0)
        var target = visible.minX
        if leftBound < visible.minX - 0.5 {
            target = leftBound
        } else if rightBound > visible.maxX + 0.5 {
            target = min(laneMin, rightBound - visible.width)
        }
        target = min(max(0, target), max(0, length - visible.width))
        guard abs(target - visible.minX) > 0.5 else { return true }
        cancelHorizontalMovement()
        applyRestorationTarget(target, scroll: scroll, document: document, geometry: (length, visible.width, visible))
        report()
        return true
    }
}
