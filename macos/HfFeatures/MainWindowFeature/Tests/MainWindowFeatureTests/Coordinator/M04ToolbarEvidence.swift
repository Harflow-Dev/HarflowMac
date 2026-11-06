import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI

// MARK: - M04ToolbarEvidence

/// Native toolbar inspection and the positive control for the system sidebar toggle.
@MainActor enum M04ToolbarEvidence {
    /// Matches the measured system identifier; the control test fails loudly if it is renamed.
    static func isSystemSidebarToggle(_ item: NSToolbarItem) -> Bool {
        isSystemSidebarToggleIdentifier(item.itemIdentifier.rawValue)
    }

    static func isSystemSidebarToggleIdentifier(_ identifier: String) -> Bool {
        identifier == NSToolbarItem.Identifier.toggleSidebar.rawValue || identifier.contains("navigationSplitView.toggleSidebar")
    }

    /// The principal context title `MainWindowNavigationView` presents for the coordinator's state.
    static func contextTitle(_ coordinator: MainWindowNavigationCoordinatorMock) -> String {
        guard coordinator.runtimeIsReady else { return "Harflow · Runtime setup" }
        switch coordinator.selection {
        case .task, .group: return "Harflow · Work"
        default: return "Harflow · New task"
        }
    }

    /// An ordered-front, key window hosting the controller at the given content size.
    static func makeWindow(_ controller: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFront(nil)
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    static func isPopulated(_ window: NSWindow) -> Bool { window.toolbar?.items.isEmpty == false }

    static func canPress(_ object: NSObject) -> Bool {
        object is any NSAccessibilityProtocol || object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
    }

    static func press(_ object: NSObject) -> Bool {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Press.self)
        return implementation(object, selector)
    }

    /// Hosts a bare `NavigationSplitView` without the removal modifier, in the same controller
    /// shape as the product, and returns its toolbar item identifiers once the toggle appears
    /// or the wait ends.
    static func controlToolbarIdentifiers() async -> [String] {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: ControlView())
        controller.sceneBridgingOptions = .all
        let window = makeWindow(controller, size: NSSize(width: 1000, height: 620))
        defer {
            window.contentViewController = nil
            window.close()
        }
        await waitUntil(timeout: 5) {
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            return window.toolbar?.items.contains(where: isSystemSidebarToggle) ?? false
        }
        return window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
    }

    private struct ControlView: View {
        var body: some View {
            HStack(spacing: 0) {
                NavigationSplitView {
                    Text("Control sidebar")
                } detail: {
                    Text("Control detail")
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Control title") }
            }
            .toolbar(removing: .title)
            .frame(minWidth: 1000, minHeight: 620)
        }
    }
}
