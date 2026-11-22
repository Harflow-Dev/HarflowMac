import AppKit
import SwiftUI

// MARK: - MessageBoxStopFocusHost

/// Captures this mounted slot's native window and responder; focus remains subject to AppKit policy.
@MainActor
final class MessageBoxStopFocusHost {
    weak var anchor: NSView?
    var eligible = false
    var makeFirstResponder: (NSWindow, NSResponder) -> Bool = { $0.makeFirstResponder($1) }

    func captureReturn() -> @MainActor () -> Bool {
        guard let anchor, let window = anchor.window, let target = nativeTarget(anchor: anchor) else { return { false } }
        return { [weak self, weak anchor, weak window, weak target] in
            guard let self, eligible, let anchor, self.anchor === anchor, let window, let target,
                  anchor.window === window, target.window === window,
                  window.isKeyWindow, NSApp.isActive, window.attachedSheet == nil,
                  !anchor.isHiddenOrHasHiddenAncestor, !anchor.visibleRect.isEmpty,
                  target.acceptsFirstResponder else { return false }
            return makeFirstResponder(window, target) && window.firstResponder === target
        }
    }

    private func nativeTarget(anchor: NSView) -> NSView? {
        let rect = anchor.convert(anchor.bounds, to: nil)
        var parent = anchor.superview
        while let region = parent {
            var candidates: [NSView] = []
            func visit(_ view: NSView) {
                guard !view.isHiddenOrHasHiddenAncestor else { return }
                let frame = view.convert(view.bounds, to: nil)
                // Never select a broad hosting view or a neighbouring composer control.
                if view !== anchor, view.acceptsFirstResponder,
                   abs(frame.midX - rect.midX) < 2, abs(frame.midY - rect.midY) < 2,
                   abs(frame.width - rect.width) < 4, abs(frame.height - rect.height) < 4 {
                    candidates.append(view)
                }
                view.subviews.forEach(visit)
            }
            visit(region)
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 { return nil }
            parent = region.superview
        }
        return nil
    }
}

struct MessageBoxStopFocusAnchor: NSViewRepresentable {
    let host: MessageBoxStopFocusHost
    let eligible: Bool

    func makeCoordinator() -> MessageBoxStopFocusHost { host }
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) {
        host.anchor = view
        host.eligible = eligible
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func dismantleNSView(_ view: NSView, coordinator: MessageBoxStopFocusHost) {
        if coordinator.anchor === view {
            coordinator.anchor = nil
            coordinator.eligible = false
        }
    }
}
