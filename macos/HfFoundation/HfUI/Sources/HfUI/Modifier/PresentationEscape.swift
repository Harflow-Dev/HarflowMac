//
//  PresentationEscape.swift
//  HfUI
//
//  Escape for the window presentation context's alerts and dialogs whose default action is a cancel.
//  SwiftUI gives `.keyboardShortcut(.defaultAction)` to that cancel button, which leaves no button
//  holding Escape. The sheet is a native `_NSAlertPanel`, so the key is answered the way Return is:
//  by clicking the sheet's own default button, never by calling the action closure.
//

import AppKit
import HfCommon
import SwiftUI

// MARK: - PresentationEscapePolicy

/// The pure decisions behind the Escape monitor, kept free of AppKit objects so each can be tested alone.
enum PresentationEscapePolicy {
    /// What the monitor does with one key press.
    enum Decision: Equatable {
        /// Not ours: the event continues to whoever owns it.
        case pass
        /// First Escape of this presentation: consume it and click the default button.
        case consumeAndClick
        /// A later Escape while the sheet is still dismissing: consume it without acting again.
        case consumeOnly
    }

    /// The facts the monitor reads from the key press and the window tree.
    struct Situation {
        var keyCode: UInt16
        var isRepeat: Bool
        var modifiers: NSEvent.ModifierFlags
        /// The event's window is the exact sheet recorded for this presentation.
        var eventIsRecordedSheet: Bool
        /// That sheet is still the host window's attached sheet.
        var sheetIsAttached: Bool
        var sheetHasNestedSheet: Bool
        /// The sheet's default button carries the title of the presentation's default action.
        var defaultButtonTitleMatches: Bool
        var alreadyConsumed: Bool
    }

    static let escapeKeyCode: UInt16 = 53
    static let modifiedMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// The title of `event`'s default action when `event` is an alert or dialog whose default action is a cancel.
    static func cancelDefaultTitle(for event: ViewEvent) -> String? {
        eligibleContent(for: event).flatMap(defaultTitle)
    }

    static func defaultTitle(of content: AlertContent) -> String? {
        content.actions.first(where: \.isDefault)?.title
    }

    /// The alert or dialog content whose default action has role `.cancel`; `nil` for everything else.
    static func eligibleContent(for event: ViewEvent) -> AlertContent? {
        guard let content = event.alert ?? event.dialog,
              let defaultAction = content.actions.first(where: \.isDefault),
              defaultAction.role == .cancel else { return nil }
        return content
    }

    /// Whether an unrecorded sheet may be adopted when Escape arrives: only after `willBeginSheet` marked this
    /// generation on this window, and only for the host's attached sheet. Without the mark nothing is adopted.
    static func mayAdoptAtKeyTime(sheetBegan: Bool, isHostAttachedSheet: Bool) -> Bool {
        sheetBegan && isHostAttachedSheet
    }

    static func decide(_ situation: Situation) -> Decision {
        guard situation.keyCode == escapeKeyCode, !situation.isRepeat,
              situation.modifiers.isDisjoint(with: modifiedMask),
              situation.eventIsRecordedSheet, situation.sheetIsAttached, !situation.sheetHasNestedSheet
        else { return .pass }
        if situation.alreadyConsumed { return .consumeOnly }
        return situation.defaultButtonTitleMatches ? .consumeAndClick : .pass
    }
}

// MARK: - PresentationEscapeAnchor

/// Background anchor that, while `presentation` is non-nil, answers Escape for the sheet that presentation opens.
struct PresentationEscapeAnchor: NSViewRepresentable {
    /// The alert or dialog being presented when its default action is a cancel; `nil` otherwise.
    let presentation: AlertContent?

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) { view.update(presentation: presentation) }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.update(presentation: nil) }

    // MARK: - AnchorView

    final class AnchorView: NSView {
        private var presentation: AlertContent?
        private var recordedSheet: NSWindow?
        /// The sheet attached when the presentation began: it belongs to someone else (or is a dismissing predecessor)
        /// and is never adopted.
        private weak var preexistingSheet: NSWindow?
        private var generation = 0
        /// Set by `willBeginSheet` on the host window for the current generation; without it nothing is adopted.
        private var sheetBegan = false
        private var consumed = false
        private var token: Any?
        private weak var observedWindow: NSWindow?

        isolated deinit {
            if let token { NSEvent.removeMonitor(token) }
            NotificationCenter.default.removeObserver(self)
        }

        /// Whether the local key monitor is currently installed.
        var isMonitoring: Bool { token != nil }

        /// The sheet this anchor will answer Escape for, once recorded.
        var ownedSheet: NSWindow? { recordedSheet }

        func update(presentation newPresentation: AlertContent?) {
            guard newPresentation != presentation else { return }
            presentation = newPresentation
            generation += 1
            recordedSheet = nil
            sheetBegan = false
            consumed = false
            preexistingSheet = newPresentation == nil ? nil : window?.attachedSheet
            reconcile()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window !== observedWindow {
                recordedSheet = nil
                sheetBegan = false
                preexistingSheet = presentation == nil ? nil : window?.attachedSheet
            }
            reconcile()
        }

        private func reconcile() {
            if let observedWindow, observedWindow !== window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willBeginSheetNotification, object: observedWindow)
                self.observedWindow = nil
            }
            if let window, observedWindow == nil {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(willBeginSheet(_:)), name: NSWindow.willBeginSheetNotification, object: window)
                observedWindow = window
            }
            if presentation != nil, window != nil, token == nil {
                token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.consume(event) == true ? nil : event
                }
            } else if !(presentation != nil && window != nil) {
                if let token { NSEvent.removeMonitor(token) }
                token = nil
            }
        }

        /// The sheet is usually not attached yet when the notification posts, so it is read again on the next main turn
        /// for the same presentation generation and window; the mark set here also lets the first Escape adopt it if
        /// that read has not run yet.
        @objc private func willBeginSheet(_ notification: Notification) {
            guard presentation != nil, let host = notification.object as? NSWindow, host === window else { return }
            sheetBegan = true
            adopt(host.attachedSheet)
            guard recordedSheet == nil else { return }
            let current = generation
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host, generation == current, window === host else { return }
                adopt(host.attachedSheet)
            }
        }

        /// Records `candidate`, once per generation, only when it appeared after this presentation began, is attached to this window and its
        /// default button is the presentation's default action. A failed candidate leaves the slot open for a later one.
        private func adopt(_ candidate: NSWindow?) {
            guard recordedSheet == nil, let presentation, let host = window, let candidate, candidate !== preexistingSheet,
                  host.attachedSheet === candidate else { return }
            let title = PresentationEscapePolicy.defaultTitle(of: presentation)
            guard let title, candidate.defaultButtonCell?.title == title else { return }
            recordedSheet = candidate
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard let presentation, let host = window else { return false }
            if recordedSheet == nil, PresentationEscapePolicy.mayAdoptAtKeyTime(
                sheetBegan: sheetBegan, isHostAttachedSheet: event.window != nil && host.attachedSheet === event.window) {
                adopt(event.window)
            }
            guard let sheet = recordedSheet else { return false }
            let cancelTitle = PresentationEscapePolicy.defaultTitle(of: presentation)
            let button = sheet.defaultButtonCell
            let decision = PresentationEscapePolicy.decide(.init(
                keyCode: event.keyCode, isRepeat: event.isARepeat, modifiers: event.modifierFlags,
                eventIsRecordedSheet: event.window === sheet,
                sheetIsAttached: host.attachedSheet === sheet,
                sheetHasNestedSheet: sheet.attachedSheet != nil,
                defaultButtonTitleMatches: button != nil && button?.title == cancelTitle,
                alreadyConsumed: consumed))
            switch decision {
            case .pass: return false
            case .consumeOnly: return true
            case .consumeAndClick:
                consumed = true
                button?.performClick(nil)
                return true
            }
        }
    }
}
