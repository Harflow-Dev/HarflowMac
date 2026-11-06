import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct AccessOptionRowTests {
    // Approved HarflowDesign 5b37a3d4d4d06b3d96c517cd384892e1ac6883cf:
    // v2/scripts/m04-proposal.js access pill/menu and + permission preview.
    @Test(arguments: [false, true])
    func givenApprovedComposer_whenAccessMenuIsInspected_thenAllExactAuthoritiesAndSelectionRemainVisible(dark: Bool) async throws {
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
            try await verifyAccessMenu(size: size, dark: dark)
        }
    }

    private func verifyAccessMenu(size: NSSize, dark: Bool) async throws {
        // given — use the actual composer and native menu, never a replacement test-only menu.
        _ = NSApplication.shared
        let previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous, forAttribute: enhanced) }
        let model = NewSessionViewModelMock(repo: "/fixture/repository", message: "Fixture access review")
        let controller = NSHostingController(rootView: NewSessionView(model).preferredColorScheme(dark ? .dark : .light))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { dispose(window) }
        try await activate(window)
        let authorities = Self.authorities
        let expectedTitles = authorities.map(\.title)

        // when — opening the production control populates SwiftUI's lazy native menu.
        // Observe only the tracking initiated synchronously by this owned control, then cancel
        // through public AppKit API so the test never leaves a menu tracking session behind.
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return nativeAccessControl(in: host, title: authorities[0].title) != nil
        }
        let control = try #require(nativeAccessControl(in: host, title: authorities[0].title),
                                   "Require the production access control through public NSButton/AX APIs.")
        var menu = try openOwnedMenu(control, expectedTitles: expectedTitles)

        // then — exact requested values, native selected state and actual selection actions.
        for authority in authorities {
            menu.update()
            let items = authorityItems(menu)
            #expect(items.map(\.title) == expectedTitles)
            let selected = try #require(items.first { $0.title == authority.title })
            let index = menu.index(of: selected)
            try #require(index >= 0)
            menu.performActionForItem(at: index)
            await waitUntil(timeout: 5) { model.freedom == authority.id }
            #expect(model.freedom == authority.id)
            host.layoutSubtreeIfNeeded()
            await DisplayFrames.waitForPresentedFrame()
            let refreshedControl = try #require(nativeAccessControl(in: host, title: authority.title))
            let refreshedMenu = try openOwnedMenu(refreshedControl, expectedTitles: expectedTitles)
            menu = refreshedMenu
            for item in authorityItems(refreshedMenu) {
                #expect(item.state == (item.title == authority.title ? .on : .off),
                        "The native access menu must identify the retained selected authority.")
            }
            #expect(accessibilityTree(window).contains { matches($0, text: authority.title) })
        }

        try await assertEnforcementPreview(window, model: model)
    }

    private func assertEnforcementPreview(_ window: NSWindow, model: NewSessionViewModelMock) async throws {
        // The selected requested authority and truthful enforcement caveat live in + options.
        let press = NSSelectorFromString("accessibilityPerformPress")
        let options = try #require(accessibilityTree(window).first {
            matches($0, text: "More task options") && $0.responds(to: press)
        })
        _ = options.perform(press)
        let expectedPreview = "Requested access: Full access. Enforcement depends on the harness; this is not an OS sandbox guarantee."
        await waitUntil(timeout: 5) {
            ownedPopovers(of: window).flatMap { accessibilityTree($0) }.contains { matches($0, text: expectedPreview) }
        }
        let popup = try #require(ownedPopovers(of: window).first {
            accessibilityTree($0).contains { matches($0, text: expectedPreview) }
        })
        #expect(accessibilityTree(popup).contains { matches($0, text: expectedPreview) })
        #expect(accessibilityTree(popup).contains { matches($0, text: "Harness qualification") })
        #expect(model.freedom == "unrestricted")
    }

    private nonisolated static let authorities = [
        (id: "read_only", title: "Read-only"),
        (id: "write_in_repo", title: "Can edit this repo"),
        (id: "publish", title: "Can publish"),
        (id: "unrestricted", title: "Full access")
        ]

    private func nativeAccessControl(in host: NSView, title: String) -> NSButton? {
        descendants(host).compactMap { $0 as? NSButton }.first { button in
            button is NSPopUpButton && accessibilityTree(button).contains { matches($0, text: title) }
        }
    }

    private func openOwnedMenu(_ button: NSButton, expectedTitles: [String]) throws -> NSMenu {
        let capture = TrackingCapture(button: button)
        NotificationCenter.default.addObserver(capture, selector: #selector(TrackingCapture.didBeginTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let deadline = Timer(timeInterval: 5, target: capture, selector: #selector(TrackingCapture.expireTracking(_:)),
                             userInfo: nil, repeats: false)
        RunLoop.main.add(deadline, forMode: .common)
        RunLoop.main.add(deadline, forMode: .eventTracking)
        defer {
            deadline.invalidate()
            NotificationCenter.default.removeObserver(capture)
            capture.menu?.cancelTracking()
        }
        button.performClick(nil)
        try #require(!capture.timedOut, "Owned access-menu tracking exceeded its bounded diagnostic deadline.")
        let menu = try #require(capture.menu,
                                "Opening the production access control must expose its real NSMenu through didBeginTrackingNotification.")
        #expect(authorityItems(menu).map(\.title) == expectedTitles)
        return menu
    }

    @MainActor private final class TrackingCapture: NSObject {
        var menu: NSMenu?
        var timedOut = false
        private weak var button: NSButton?

        init(button: NSButton) { self.button = button }

        @objc func didBeginTracking(_ notification: Notification) {
            guard let menu = notification.object as? NSMenu else { return }
            self.menu = menu
            postOwnedEscape()
        }

        @objc func expireTracking(_: Timer) {
            timedOut = true
            postOwnedEscape()
            menu?.cancelTracking()
            button?.menu?.cancelTracking()
        }

        private func postOwnedEscape() {
            guard let window = button?.window, NSApp.isActive, window.isMainWindow,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                              isARepeat: false, keyCode: 53) else { return }
            NSApp.postEvent(event, atStart: true)
        }
    }

    private func activate(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 5) { NSApp.isActive && window.isKeyWindow }
        try #require(NSApp.isActive && window.isKeyWindow,
                     "Native menu/focus/capture requires this fixture to be the active key window.")
    }

    private func authorityItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }
    }

    private func ownedPopovers(of window: NSWindow, visibleOnly: Bool = true) -> [NSWindow] {
        func collect(_ owner: NSWindow) -> [NSWindow] {
            (owner.childWindows ?? []).flatMap { [$0] + collect($0) }
        }
        return collect(window).filter { !visibleOnly || $0.isVisible }
    }

    private func dispose(_ owner: NSWindow) {
        for popup in ownedPopovers(of: owner, visibleOnly: false).reversed() {
            popup.orderOut(nil)
            popup.close()
        }
        owner.contentView = nil
        owner.close()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func accessibilityTree(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result = [object]
            if let window = object as? NSWindow, let content = window.contentView { result += collect(content) }
            if let view = object as? NSView { result += view.subviews.flatMap(collect) }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                result += children.flatMap(collect)
            }
            return result
        }
        return collect(root)
    }

    private func matches(_ object: NSObject, text: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == text
        }
    }
}
