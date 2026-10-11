import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct AccessOptionRowTests {
    @Test func givenTheDefaultNewSessionAtItsStandardWidth_whenHosted_thenAccessCardsUseTwoColumnsAndKeepTheCaveatVisible() async throws {
        // given — host the production sheet with its existing preview model at the standard width.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: NewSessionView(NewSessionViewModelMock.sample)
            .frame(width: 760, height: 900))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let previousEnhanced = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        defer { NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")) }

        // when
        await DisplayFrames.waitForPresentedFrame()
        await waitUntil(timeout: 5) { host.layoutSubtreeIfNeeded(); return accessControls(in: host).count == 4 }

        // then — all four cards are actual AX buttons, split into two rows, and retain the exact
        // enforcement caveat outside the cards. Their descriptions fit one line at this width.
        let controls = accessControls(in: host)
        #expect(controls.count == 4)
        let frames = try controls.map { try #require(frame(in: $0)) }
        #expect(Set(frames.map { Int($0.midY.rounded()) }).count == 2)
        #expect(Set(frames.map { Int($0.midX.rounded()) }).count == 2)
        let secondaryFont = NSFont.systemFont(ofSize: PbTextStyle.secondary.pointSize)
        for control in controls {
            let label = try #require(accessibilityString(control, "accessibilityLabel"))
            let detail = try #require([
                "Requests read-only repo review.", "Requests repo edits, no publishing.",
                "Requests edits and publish attempts.", "Requests broad access; use sparingly."
            ].first { label.contains($0) })
            let availableWidth = max(1, (frame(in: control)?.width ?? 1)
                - PbRadius.Metrics.spacing12 * 2 - PbRadius.Metrics.spacing16 - PbRadius.Metrics.spacing12)
            let measured = (detail as NSString).boundingRect(
                with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: secondaryFont], context: nil
            )
            let lineHeight = secondaryFont.ascender - secondaryFont.descender + secondaryFont.leading
            #expect(measured.height <= lineHeight + 1)
        }
        #expect(allAccessibilityObjects(in: host).contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                accessibilityString(object, $0)?.contains("How strictly this is enforced depends on the agent.") == true
            }
        })
    }

    private func accessControls(in root: NSView) -> [NSObject] {
        let details = [
            "Requests read-only repo review.", "Requests repo edits, no publishing.",
            "Requests edits and publish attempts.", "Requests broad access; use sparingly."
        ]
        return allAccessibilityObjects(in: root).filter { object in
            accessibilityString(object, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && details.contains { detail in (accessibilityString(object, "accessibilityLabel") ?? "").contains(detail) }
        }
    }

    private func frame(in object: NSObject) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> CGRect
        let getter = unsafeBitCast(method, to: FrameGetter.self)
        return getter(object, selector)
    }

    private func allAccessibilityObjects(in root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        for view in [root] + root.subviews.flatMap(allViews) {
            for object in accessibilityTree(view) where seen.insert(ObjectIdentifier(object)).inserted {
                result.append(object)
            }
        }
        return result
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func accessibilityTree(_ object: NSObject) -> [NSObject] {
        var result = [object]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return result }
        for child in children { if let child = child as? NSObject { result += accessibilityTree(child) } }
        return result
    }

    private func accessibilityString(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}
