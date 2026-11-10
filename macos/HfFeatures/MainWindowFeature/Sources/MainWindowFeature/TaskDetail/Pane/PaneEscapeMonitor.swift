//
//  PaneEscapeMonitor.swift
//  MainWindowFeature
//
//  Escape for the standalone right pane when nothing in the view holds focus. SwiftUI's `onExitCommand` reaches a
//  handler only through a focused descendant, so an overlay opened earlier (or a persisted open pane) could not be
//  dismissed from the keyboard. This installs a key-down monitor scoped to one window and passes Escape through
//  wherever something else owns it.
//

import AppKit
import SwiftUI

// MARK: - PaneEscapeMonitor

/// Background view that, while `isActive`, offers a plain Escape to `handle`. `handle` returns whether it used the key;
/// only then is the event consumed. Escape is never taken from a text field's field editor, from a sheet, from another
/// window (popovers, panels), from a key press with Command, Option, Control or Shift, or while focus sits in another
/// region of the window.
///
/// Invariant: `handle` must have no side effects when it returns `false`, so a declined event costs nothing.
struct PaneEscapeMonitor: NSViewRepresentable {
    let isActive: Bool
    var toolbarOriginIdentifier: String?
    let handle: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handle = handle
        view.toolbarOriginIdentifier = toolbarOriginIdentifier
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.setActive(false) }

    // MARK: - MonitorView

    /// Owns the monitor token; removed whenever the pane closes or the view leaves its window.
    final class MonitorView: NSView {
        /// Set on every update and cleared when the monitor goes inactive or is dismantled. A detached or inactive view
        /// never reaches it: the monitor callback checks `wantsMonitor` and the window first.
        var handle: () -> Bool = { false }
        var toolbarOriginIdentifier: String?
        private var token: Any?

        isolated deinit {
            if let token { NSEvent.removeMonitor(token) }
        }

        private var wantsMonitor = false

        /// Whether the local key monitor is currently installed.
        var isMonitoring: Bool { token != nil }

        func setActive(_ active: Bool) {
            wantsMonitor = active
            reconcile()
            if !active {
                handle = { false }
                toolbarOriginIdentifier = nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { toolbarOriginIdentifier = nil }
            reconcile()
        }

        /// Installs the monitor only while active and in a window, and removes it otherwise. It never touches `handle`,
        /// which `updateNSView` has just set; only going inactive or dismantling clears it.
        private func reconcile() {
            if wantsMonitor, window != nil, token == nil {
                token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.consume(event) == true ? nil : event
                }
            } else if !(wantsMonitor && window != nil) {
                if let token { NSEvent.removeMonitor(token) }
                token = nil
            }
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard wantsMonitor, let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  event.keyCode == Self.escapeKeyCode, !event.isARepeat,
                  event.modifierFlags.isDisjoint(with: Self.modifiedMask),
                  !(window.firstResponder is NSText), ownsFocus(in: window) else { return false }
            return handle()
        }

        /// Whether focus is nowhere in particular or inside the task detail region this view fills. A text editor is
        /// excluded before this. A first responder that contains this view (the hosting view, where SwiftUI keeps its own
        /// focus) is allowed, because AppKit cannot tell which SwiftUI region is focused; any other view must lie within
        /// this view's bounds, so a focused sidebar control keeps its Escape. The current reveal origin is the sole
        /// toolbar exception: first Escape can return keyboard focus to that visible item before a second closes the pane.
        private func ownsFocus(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder, responder !== window else { return true }
            guard let view = responder as? NSView else { return false }
            if isDescendant(of: view) { return true }
            if let identifier = toolbarOriginIdentifier,
               let item = window.toolbar?.visibleItems?.first(where: { $0.itemIdentifier.rawValue == identifier }),
               let origin = item.view, origin.window === window, !origin.isHiddenOrHasHiddenAncestor,
               !view.isHiddenOrHasHiddenAncestor, view === origin || view.isDescendant(of: origin) {
                return true
            }
            let region = convert(bounds, to: nil)
            let frame = view.convert(view.bounds, to: nil)
            return region.contains(CGPoint(x: frame.midX, y: frame.midY))
        }

        /// The user-driven modifiers an unmodified Escape must not carry; Caps Lock, numeric pad and function flags
        /// do not disable it.
        private static var modifiedMask: NSEvent.ModifierFlags { [.command, .option, .control, .shift] }

        private static var escapeKeyCode: UInt16 { 53 }
    }
}
