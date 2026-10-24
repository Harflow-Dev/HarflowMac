import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarAppearanceControlHostedTests {
    @Test(arguments: [AppAppearance.light, AppAppearance.dark, AppAppearance.system])
    func givenAppearanceControl_whenHosted_thenItExposesAllChoicesAndSelectedValue(_ selected: AppAppearance) async throws {
        // given
        _ = NSApplication.shared
        let enhancedInterface = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(enhancedInterface)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhancedInterface)
        var pressed: AppAppearance?
        let controller = NSHostingController(rootView: SidebarAppearanceControl(appearance: selected, onSelect: { pressed = $0 }).padding())
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let frame = NSRect(x: 0, y: 0, width: 240, height: 96)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            NSApplication.shared.accessibilitySetValue(previousEnhancedInterface, forAttribute: enhancedInterface)
        }

        // when — allow native layout and accessibility bridging to finish in the mounted window.
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elements = accessibilityTree(window)
            return ["Light", "Dark", "System"].allSatisfy { title in
                elements.contains { matches($0, title: title) && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) }
            } && elements.contains { matches($0, title: selected.rawValue.capitalized) && isSelected($0) }
        }

        // then — require the production accessibility choices and a working native press action.
        let elements = accessibilityTree(window)
        for title in ["Light", "Dark", "System"] {
            #expect(elements.contains { matches($0, title: title) })
        }
        #expect(elements.contains { matches($0, title: selected.rawValue.capitalized) && isSelected($0) })
        let press = NSSelectorFromString("accessibilityPerformPress")
        let dark = try #require(elements.first { matches($0, title: "Dark") && $0.responds(to: press) })
        _ = dark.perform(press)
        await waitUntil { pressed == .dark }
        #expect(pressed == .dark)

        // Opt-in visual evidence uses the actual mounted view's display cache.
        if let directory = ProcessInfo.processInfo.environment["HARFLOW_PREFERENCES_CAPTURE_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("appearance-\(selected.rawValue).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
    }

    private func accessibilityTree(_ root: NSObject) -> [NSObject] {
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

    private func matches(_ object: NSObject, title: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { accessibilityString(object, $0) == title }
    }

    private func isSelected(_ object: NSObject) -> Bool {
        if accessibilityString(object, "accessibilityValue") == "Selected" { return true }
        let selector = NSSelectorFromString("isAccessibilitySelected")
        guard object.responds(to: selector) else { return false }
        return object.value(forKey: "accessibilitySelected") as? Bool == true
    }

    private func accessibilityString(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.perform(NSSelectorFromString(key))?.takeUnretainedValue() as? String
    }
}
