import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - ActivityCardPresentationTests

/// The shared activity views used by detail, Parallel and workflow lanes retain bounded layout and separate actions.
@MainActor @Suite(.serialized) struct ActivityCardPresentationTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenFilePillsInANarrowLane_whenHosted_thenPillsWrapAndLongNamesRemainBounded(scheme: ColorScheme) {
        // given
        _ = NSApplication.shared
        let names = ["AppDelegate.swift", "KeychainStore.swift", "AuthenticationCoordinator.swift", String(repeating: "LongName", count: 12)]
        func height(_ width: CGFloat) -> CGSize {
            let host = NSHostingView(rootView: FilePillsView(names: names, overflowCount: 2)
                .frame(width: width)
.fixedSize(horizontal: false, vertical: true)
.preferredColorScheme(scheme))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        // when
        let narrow = height(PbRadius.Metrics.activityPreviewWidth)
        let wide = height(PbRadius.Metrics.taskColumnMaxWidth)
        // then
        #expect(narrow.width <= PbRadius.Metrics.activityPreviewWidth)
        #expect(narrow.height > wide.height)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenAnExpandedReadCard_whenPressingDisclosureAndFilePill_thenTheirExistingActionsStaySeparate(scheme: ColorScheme) async throws {
        // given
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let item = PreviewFixtures.toolItem(tool: "Read", category: "read", command: nil, path: "/repo/AppDelegate.swift", pending: true)
        guard case .tool(let call, let result) = item.body else { Issue.record("Expected tool fixture"); return }
        let group = ToolGroup(id: "group", taskID: "task", bucket: .read,
            members: [ToolGroupMember(id: "member", call: call, result: result, timestamp: nil, live: true)])
        var toggles = 0
        var opened: [URL] = []
        let host = NSHostingView(rootView: ToolGroupCardView(group: group, start: nil, isExpanded: true, onToggle: { toggles += 1 })
            .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
            .environment(\.pbReduceMotionOverride, true)
            .preferredColorScheme(scheme)
            .frame(width: PbRadius.Metrics.activityPreviewWidth))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: PbRadius.Metrics.activityPreviewWidth,
                                                 height: PbRadius.Metrics.sidebarCompactPreviewHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return tree(host).contains { string($0, "accessibilityValue") == "Expanded" }
        }
        let disclosure = try #require(tree(host).first { string($0, "accessibilityValue") == "Expanded" })
        let pill = try #require(tree(host).first { string($0, "accessibilityLabel") == "Open AppDelegate.swift" })
        // when — the card disclosure and file pill are distinct native accessibility actions.
        #expect(press(disclosure))
        #expect(press(pill))
        // then
        #expect(toggles == 1)
        #expect(opened.map(\.absoluteString) == ["/repo/AppDelegate.swift"])
        #expect(host.fittingSize.width <= PbRadius.Metrics.activityPreviewWidth)
    }

    private func tree(_ element: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = element.responds(to: selector)
            ? element.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        let subviews = (element as? NSView)?.subviews ?? []
        return [element] + children.flatMap(tree) + subviews.flatMap(tree)
    }

    private func string(_ element: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    private func press(_ element: NSObject) -> Bool {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(element.method(for: selector), to: Press.self)
        return implementation(element, selector)
    }
}
