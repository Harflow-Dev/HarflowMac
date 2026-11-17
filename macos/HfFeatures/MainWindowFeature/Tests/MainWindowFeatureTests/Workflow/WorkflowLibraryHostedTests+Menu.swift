import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowLibraryHostedTests + native menu and keyboard

extension WorkflowLibraryHostedTests {
    @Test func givenLibraryHeader_whenNativeMenuIsOpenedAndSelected_thenBothCreationRoutesAreExact() async throws {
        // given
        let h = WorkflowLibraryHostedFixture.make()
        let fixture = host(h.vm, size: CGSize(width: 1000, height: 620), appearance: .light)
        defer { h.vm.didDisappear(); fixture.close() }
        try await activate(fixture)
        await fixture.settle { fixture.descendants.contains { $0 is NSPopUpButton } }
        let button = try #require(fixture.descendants.compactMap { $0 as? NSPopUpButton }.first)
        // when — the first menu opens with an owned-window Space event, the second through its native button.
        for (index, title) in ["Blank workflow", "Generate with agent…"].enumerated() {
            let capture = LibraryMenuCapture(button: button)
            NotificationCenter.default.addObserver(capture, selector: #selector(LibraryMenuCapture.didBegin(_:)),
                                                   name: NSMenu.didBeginTrackingNotification, object: nil)
            let deadline = Timer(timeInterval: 5, target: capture, selector: #selector(LibraryMenuCapture.expire(_:)), userInfo: nil, repeats: false)
            RunLoop.main.add(deadline, forMode: .common)
            RunLoop.main.add(deadline, forMode: .eventTracking)
            defer { deadline.invalidate(); NotificationCenter.default.removeObserver(capture); capture.menu?.cancelTracking() }
            if index == 0 {
                try #require(fixture.window.makeFirstResponder(button))
                librarySpace(fixture.window)
            } else { button.performClick(nil) }
            let menu = try #require(capture.menu)
            try #require(!capture.timedOut)
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Blank workflow", "Generate with agent…"])
            let item = try #require(menu.items.firstIndex { $0.title == title })
            #expect(menu.items[item].isEnabled)
            menu.performActionForItem(at: item)
        }
        // then
        #expect(h.routing.creations == [false, true])
        #expect(h.useCase.contexts.count == 1)
    }

    @Test func givenLibraryActions_whenFocusedSpaceIsDelivered_thenEditAndRunRouteThroughNativeKeyboard() async throws {
        // given
        let h = WorkflowLibraryHostedFixture.make()
        let fixture = host(h.vm, size: CGSize(width: 1000, height: 620), appearance: .light)
        defer { h.vm.didDisappear(); fixture.close() }
        try await activate(fixture)
        await fixture.settle { fixture.element("Edit implement-review") != nil }
        // when — retain the platform policy; never change keyboard preferences to qualify a test.
        guard NSApp.isFullKeyboardAccessEnabled else {
            try recordKeyboardPolicy("unverified: Full Keyboard Access is off; macOS ignores SwiftUI button AX focus requests")
            return
        }
        for label in ["Edit implement-review", "Run implement-review"] {
            let element = try #require(fixture.element(label))
            let setter = NSSelectorFromString("setAccessibilityFocused:")
            try #require(element.responds(to: setter))
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let setFocus = unsafeBitCast(element.method(for: setter), to: Setter.self)
            setFocus(element, setter, true)
            await fixture.settle { libraryIsFocused(element) }
            try #require(libraryIsFocused(element))
            librarySpace(fixture.window)
        }
        // then
        await fixture.settle { h.routing.runs == ["implement-review"] }
        #expect(h.routing.edits == ["implement-review"])
        #expect(h.routing.runs == ["implement-review"])
        try recordKeyboardPolicy("verified: owned-window Space activated focused Edit and Run")
    }

    private func libraryIsFocused(_ element: NSObject) -> Bool {
        let selector = NSSelectorFromString("isAccessibilityFocused")
        guard element.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }

    private func librarySpace(_ window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                              isARepeat: false, keyCode: 49) else { Issue.record("Could not construct owned keyboard event"); return }
            window.sendEvent(event)
        }
    }

    private func recordKeyboardPolicy(_ outcome: String) throws {
        print("WORKFLOW_LIBRARY_KEYBOARD " + outcome)
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_WORKFLOW_LIBRARY_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try outcome.write(to: directory.appendingPathComponent("workflow-library-keyboard.txt"), atomically: true, encoding: .utf8)
    }
}

// MARK: - LibraryMenuCapture

@MainActor private final class LibraryMenuCapture: NSObject {
    weak var button: NSButton?
    var menu: NSMenu?
    var timedOut = false
    init(button: NSButton) { self.button = button }
    @objc func didBegin(_ notification: Notification) {
        menu = notification.object as? NSMenu
        perform(#selector(closeTracking(_:)), with: nil, afterDelay: 0, inModes: [.eventTracking])
    }

    @objc func closeTracking(_: Any?) { menu?.cancelTracking() }
    @objc func expire(_: Timer) { timedOut = true; menu?.cancelTracking(); button?.menu?.cancelTracking() }
}
