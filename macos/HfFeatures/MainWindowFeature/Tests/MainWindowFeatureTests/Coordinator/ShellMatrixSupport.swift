import AppKit
import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - ShellMatrix

/// Accessibility-tree helpers and the shell invariants shared by the M05 task-state matrix suites. They are copies of the
/// M04 matrix helpers (`M04StateMatrixHostedTests`), kept separate so the M04 suite is untouched.
@MainActor enum ShellMatrix {

    /// The sizes every matrix suite mounts: the large window and the approved minimum.
    static let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)]

    static func hasIdentifier(_ object: NSObject, _ identifier: String) -> Bool {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to: selector) && object.perform(selector)?.takeUnretainedValue() as? String == identifier
    }

    static func accessibilityFrame(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }

    static func contains(_ text: String, in window: NSWindow) -> Bool { tree(window).contains { matches($0, text) } }

    static func matches(_ object: NSObject, _ text: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            let selector = NSSelectorFromString(key)
            guard object.responds(to: selector) else { return false }
            return object.perform(selector)?.takeUnretainedValue() as? String == text
        }
    }

    /// Whether any element's label, title or value starts with `prefix`.
    static func hasPrefix(_ prefix: String, in window: NSWindow) -> Bool {
        tree(window).contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
                let selector = NSSelectorFromString(key)
                guard object.responds(to: selector) else { return false }
                return (object.perform(selector)?.takeUnretainedValue() as? String)?.hasPrefix(prefix) == true
            }
        }
    }

    static func tree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
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

    static func string(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    static func label(_ object: NSObject) -> String? { string(object, "accessibilityLabel") }
    static func value(_ object: NSObject) -> String? { string(object, "accessibilityValue") }

    /// The first element whose label, title, value or identifier equals `text`.
    static func element(_ text: String, in window: NSWindow) -> NSObject? {
        tree(window).first { matches($0, text) || hasIdentifier($0, text) }
    }

    /// Every element whose label, title, value or identifier equals `text`.
    static func elements(_ text: String, in window: NSWindow) -> [NSObject] {
        tree(window).filter { matches($0, text) || hasIdentifier($0, text) }
    }

    /// Whether an element with exactly this label, title, value or identifier exists.
    static func has(_ text: String, in window: NSWindow) -> Bool { element(text, in: window) != nil }

    /// The accessibility enabled flag, `nil` when the element does not report one.
    static func isEnabled(_ object: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return getter(object, selector)
    }

    /// The accessibility modal flag of an element.
    static func isModal(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("isAccessibilityModal")
        if object.responds(to: selector) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.isAccessibilityModal() }
        return false
    }

    static func press(_ object: NSObject) -> Bool { M04ToolbarEvidence.press(object) }

    static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    // MARK: Shell invariants

    /// What every matrix state keeps true of the shell around the task: the requested size, the 264 point sidebar (or the
    /// 56 point rail), no search or backend filter, no system sidebar toggle, and no navigation taps recorded.
    static func assertShellInvariants(_ window: NSWindow, host: NSView, size: NSSize, collapsed: Bool = false,
                                      coordinator: MainWindowNavigationCoordinatorMock, name: String) throws {
        #expect(abs(host.bounds.width - size.width) < 1, "host width \(name)")
        #expect(abs(host.bounds.height - size.height) < 1, "host height \(name)")
        #expect(window.frame.height > host.bounds.height, "window frame includes the title bar \(name)")
        let content = window.convertToScreen(host.bounds)
        let settings = try #require(tree(window).first { matches($0, "Settings") }, "Settings \(name)")
        let settingsFrame = try #require(accessibilityFrame(settings))
        #expect(settingsFrame.width > 0 && settingsFrame.height > 0)
        #expect(content.insetBy(dx: -1, dy: -1).contains(settingsFrame), "Settings inside the content \(name)")
        if collapsed {
            let rail = try #require(tree(window).first { matches($0, "Navigation rail") }, "rail \(name)")
            let railFrame = try #require(accessibilityFrame(rail))
            #expect(abs(railFrame.width - 56) < 1, "rail width \(name)")
        } else {
            let sidebars = tree(window).filter { hasIdentifier($0, "main-window-sidebar") }
            #expect(sidebars.count == 1, "one semantic sidebar \(name)")
            let sidebar = try #require(sidebars.first)
            let sidebarFrame = try #require(accessibilityFrame(sidebar))
            #expect(abs(sidebarFrame.width - 264) < 1, "sidebar width \(name)")
            #expect(content.insetBy(dx: -1, dy: -1).contains(sidebarFrame), "sidebar inside the content \(name)")
        }
        #expect(!contains("Search", in: window), "no Search \(name)")
        #expect(!contains("Filter by backend", in: window), "no backend filter \(name)")
        #expect(!descendants(host).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" },
                "no history search \(name)")
        let toolbar = try #require(window.toolbar, "toolbar \(name)")
        #expect(!toolbar.items.isEmpty)
        #expect(!toolbar.items.contains(where: M04ToolbarEvidence.isSystemSidebarToggle),
                "system sidebar toggle \(name) \(toolbar.items.map(\.itemIdentifier.rawValue))")
        // The task principal is not centred on the window by rule (only the fallback context title is), so no centring check.
        #expect(coordinator.sidebarViewModel.runtimeSetupTapCount == 0, "no runtime setup tap \(name)")
        #expect(coordinator.sidebarViewModel.newSessionTapCount == 0, "no new session tap \(name)")
        #expect(coordinator.listingRetryCount == 0, "no listing retry \(name)")
    }
}
