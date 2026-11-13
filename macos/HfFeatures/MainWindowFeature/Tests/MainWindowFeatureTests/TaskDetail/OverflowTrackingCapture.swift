import AppKit

// MARK: - OverflowTrackingCapture

/// Opens a SwiftUI `Menu`'s native popup through its `NSPopUpButton` and captures only its own tracking notification, then
/// cancels tracking so the menu is read without staying open.
@MainActor final class OverflowTrackingCapture: NSObject {
    var menu: NSMenu?
    var timedOut = false
    weak var button: NSButton?
    init(button: NSButton) { self.button = button }

    @objc func didBegin(_ notification: Notification) {
        menu = notification.object as? NSMenu
        // Cancel on the next tracking turn, after AppKit has entered its nested menu loop.
        perform(#selector(closeTracking(_:)), with: nil, afterDelay: 0, inModes: [.eventTracking])
    }

    @objc func closeTracking(_: Any?) {
        escape()
        menu?.cancelTracking()
    }

    @objc func expire(_: Timer) {
        timedOut = true
        escape()
        menu?.cancelTracking()
        button?.menu?.cancelTracking()
    }

    private func escape() {
        guard let window = button?.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(event, atStart: true)
    }
}
