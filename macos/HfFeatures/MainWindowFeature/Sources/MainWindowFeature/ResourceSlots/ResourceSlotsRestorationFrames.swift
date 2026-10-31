import AppKit
import QuartzCore
import SwiftUI

// MARK: - ResourceSlotsRestorationFrames

/// Presented-frame seam. Hidden/detached views do not receive their NSView display-link callbacks.
struct ResourceSlotsRestorationFrames: NSViewRepresentable {
    let active: Bool
    let onFrame: @MainActor () -> Void

    func makeNSView(context _: Context) -> FrameView { FrameView(frame: .zero) }

    func updateNSView(_ view: FrameView, context _: Context) {
        view.onFrame = onFrame
        view.setActive(active)
    }

    static func dismantleNSView(_ view: FrameView, coordinator _: Void) { view.setActive(false) }

    @MainActor
    final class FrameView: NSView {
        var onFrame: (@MainActor () -> Void)?
        private var requested = false
        private var link: CADisplayLink?

        func setActive(_ active: Bool) {
            requested = active
            reconcile()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reconcile()
        }

        private func reconcile() {
            guard requested, window != nil else {
                link?.invalidate()
                link = nil
                return
            }
            guard link == nil else { return }
            let display = displayLink(target: self, selector: #selector(presented(_:)))
            link = display
            display.add(to: .main, forMode: .common)
        }

        @objc private func presented(_: CADisplayLink) { onFrame?() }
    }
}
