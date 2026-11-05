import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TimelineHeaderViewportTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenPresentedEmptyTimeline_whenRowsAndCountArrive_thenNativeFeedViewportIsUnchanged(scheme: ColorScheme) async throws {
        // given — observe an actual mounted empty native feed before publishing any count or rows.
        let model = HeaderViewportFixture()
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let controller = NSHostingController(rootView: HeaderViewportSurface(model: model)
            .frame(width: 420, height: 450)
.preferredColorScheme(scheme))
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        await waitUntil { feed(controller.view)?.contentView.bounds.height ?? 0 > 0 }
        let scroll = try #require(feed(controller.view))
        try #require(scroll.contentView.bounds.height > 0)
        await DisplayFrames.waitForPresentedFrame()
        try #require(abs(controller.view.bounds.width - 420) <= 1 && abs(controller.view.bounds.height - 450) <= 1)
        #expect(model.rows.isEmpty && model.count == nil)
        let original = scroll.convert(scroll.bounds, to: controller.view)
        #expect(original.width > 0 && original.height > 0)
        // when
        model.rows = [ConversationTimelineRow(id: "header-row", taskID: "header-task", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "Bounded captured activity wraps. ", count: 200), seq: 1)), live: false)]
        model.count = "1 activity item"
        func populatedHeaderIsAllocated() -> Bool {
            guard let headerFrame = headerFrame("1 activity item", root: controller.view, window: window),
                  let table = scroll.documentView as? NSTableView, table.numberOfRows > 0 else { return false }
            // Wait for the real header to occupy its own space, rather than sampling before allocation.
            return headerFrame.height > 0 && scroll.convert(scroll.bounds, to: nil).maxY <= headerFrame.minY + 1
        }
        await waitUntil { populatedHeaderIsAllocated() }
        try #require(populatedHeaderIsAllocated(), "The populated header must occupy space outside the native feed before comparison")
        await DisplayFrames.waitForPresentedFrame()
        // then — the previous conditional-header implementation loses one whole text-line slot here.
        let populated = scroll.convert(scroll.bounds, to: controller.view)
        #expect(abs(populated.minY - original.minY) <= 1)
        #expect(abs(populated.height - original.height) <= 1)
        #expect(abs(populated.width - original.width) <= 1)
        #expect(headerFrame("1 activity item", root: controller.view, window: window) != nil)
    }

    private func feed(_ root: NSView) -> NSScrollView? {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(root).compactMap { $0 as? ActivityFeedNativeScrollView }.first
    }

    private func headerFrame(_ label: String, root: NSView, window: NSWindow) -> CGRect? {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> CGRect? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let accessible = object as? any NSAccessibilityProtocol
            let matches = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains { key in
                let selector = NSSelectorFromString(key)
                return object.responds(to: selector) && object.perform(selector)?.takeUnretainedValue() as? String == label
            }
            if matches {
                if let accessible { return window.convertFromScreen(accessible.accessibilityFrame()) }
                if object.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let value = object.value(forKey: "accessibilityFrame") as? NSValue { return window.convertFromScreen(value.rectValue) }
            }
            let children = accessible?.accessibilityChildren() as? [NSObject] ?? []
            let selector = NSSelectorFromString("accessibilityChildren")
            let fallback = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
            for child in children + fallback + ((object as? NSView)?.subviews ?? []) {
                if let result = walk(child) { return result }
            }
            return nil
        }
        return walk(root)
    }
}

@Observable @MainActor
private final class HeaderViewportFixture {
    var count: String?
    var rows: [ConversationTimelineRow] = []
}

@MainActor
private struct HeaderViewportSurface: View {
    let model: HeaderViewportFixture
    var body: some View {
        TimelinePaneView(model: TimelinePaneModel(stepCountText: model.count, rows: model.rows,
            start: nil, emptyText: "No captured rows", subTaskStrip: nil, isLoading: false))
    }
}
