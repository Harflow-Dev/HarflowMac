import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct FirstRunSidebarLayoutTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenRuntimeSetupRequired_whenSidebarFirstMountsAndResizes_thenSetupControlsRemainInContentLayout(
        _ appearanceName: NSAppearance.Name
    ) async throws {
        let state = RuntimeSetupState.installationRequired(installedVersion: nil, requiredVersion: "0.0.2")
        let viewModel = SidebarViewModelMock(runtimeSetupState: state)
        let fixture = try SidebarFirstRunWindowFixture(viewModel: viewModel, appearanceName: appearanceName)
        defer { fixture.close() }

        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1200, height: 740)] {
            fixture.window.setContentSize(size)
            await fixture.waitForSetupControls()
            let contentLayout = fixture.window.contentLayoutRect
            let title = try #require(fixture.element(identifier: "runtimeSetup.title", label: state.title))
            let action = try #require(fixture.element(identifier: "runtimeSetup.action", label: state.actionTitle!))
            let footer = try #require(fixture.element(label: "Settings"))
            let titleFrame = try #require(fixture.frame(of: title))
            let actionFrame = try #require(fixture.frame(of: action))
            let footerFrame = try #require(fixture.frame(of: footer))

            #expect(titleFrame.isContained(in: contentLayout))
            #expect(actionFrame.isContained(in: contentLayout))
            #expect(footerFrame.isContained(in: contentLayout))
        }
    }

    @Test func givenLongRuntimeFailure_whenSidebarFirstMounts_thenFailureContentHasScrollableReachability() async throws {
        let message = String(repeating: "The managed runtime could not be prepared. ", count: 24)
        let state = RuntimeSetupState.failed(message)
        let viewModel = SidebarViewModelMock(runtimeSetupState: state)
        let fixture = try SidebarFirstRunWindowFixture(viewModel: viewModel, appearanceName: .aqua)
        defer { fixture.close() }

        await fixture.waitForSetupControls()
        let scrollViews = fixture.descendants.compactMap { $0 as? NSScrollView }
        let failure = try #require(fixture.element(identifier: "runtimeSetup.error", label: state.detail))
        let retry = try #require(fixture.element(identifier: "runtimeSetup.action", label: state.actionTitle!))
        let footer = try #require(fixture.element(label: "Settings"))
        let contentLayout = fixture.window.contentLayoutRect
        let failureFrame = try #require(fixture.frame(of: failure))
        let footerFrame = try #require(fixture.frame(of: footer))
        let scrollView = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first)

        #expect(scrollViews.contains { $0.hasVerticalScroller || $0.documentView?.frame.height ?? 0 > $0.bounds.height })
        #expect(failureFrame.intersects(contentLayout))
        #expect(footerFrame.intersects(contentLayout), "The footer must remain visible while setup content scrolls")

        let maximumOffset = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            guard let retryFrame = fixture.frame(of: retry) else { return false }
            return retryFrame.intersects(fixture.window.contentLayoutRect)
        }
        let retryFrame = try #require(fixture.frame(of: retry))
        let footerAfterScroll = try #require(fixture.frame(of: footer))
        #expect(retryFrame.intersects(contentLayout), "Retry must remain reachable below a long setup error")
        #expect(footerAfterScroll.intersects(contentLayout), "The footer must remain visible after scrolling setup content")
    }

    @Test func givenRuntimeSetupRequired_whenRuntimeBecomesReady_thenSidebarReturnsToTaskList() async throws {
        let viewModel = SidebarViewModelMock(
            runtimeSetupState: .installationRequired(installedVersion: nil, requiredVersion: "0.0.2")
        )
        let fixture = try SidebarFirstRunWindowFixture(viewModel: viewModel, appearanceName: .aqua)
        defer { fixture.close() }

        await fixture.waitForSetupControls()
        #expect(fixture.element(label: "Prepare Harflow") != nil)

        viewModel.runtimeSetupState = .ready
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            return fixture.textField(matchingPlaceholder: "Search loaded history") != nil
        }
        #expect(fixture.element(label: "Prepare Harflow") == nil)
        #expect(fixture.textField(matchingPlaceholder: "Search loaded history") != nil)
    }
}

@MainActor private final class SidebarFirstRunWindowFixture {
    let window: NSWindow
    let host: NSHostingView<AnyView>
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousEnhancedUI: Bool

    convenience init(viewModel: SidebarViewModelMock, appearanceName: NSAppearance.Name) throws {
        let root = AnyView(
            NavigationSplitView {
                SidebarView(viewModel).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
            } detail: {
                Text("Detail").frame(minWidth: 720, minHeight: 620)
            }
            .toolbar(removing: .title)
        )
        try self.init(root: root, appearanceName: appearanceName)
    }

    init(root: AnyView, appearanceName: NSAppearance.Name) throws {
        _ = NSApplication.shared
        self.previousEnhancedUI = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI) as? Bool ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        self.host = NSHostingView(rootView: root)
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "first-run-sidebar-layout")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = host
        window.orderFront(nil)
    }

    var descendants: [NSView] { [host] + host.subviews.flatMap(descendants(of:)) }

    func waitForSetupControls() async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return element(label: "Prepare Harflow") != nil || element(label: "Setup did not finish") != nil
        }
    }

    func textField(matching value: String) -> NSTextField? {
        descendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == value }
    }

    func textField(matchingPlaceholder value: String) -> NSTextField? {
        descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == value }
    }

    func element(label: String) -> NSObject? {
        accessibilityElements.first { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                accessibilityString(element, $0) == label
            }
        }
    }

    func element(identifier: String, label: String) -> NSObject? {
        element(identifier: identifier) ?? element(label: label)
    }

    private func element(identifier: String) -> NSObject? {
        accessibilityElements.first { accessibilityString($0, "accessibilityIdentifier") == identifier }
    }

    func button(matching value: String) -> NSButton? {
        descendants.compactMap { $0 as? NSButton }.first { $0.title == value }
    }

    func button(matchingAccessibilityLabel value: String) -> NSButton? {
        descendants.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == value }
    }

    func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: window.contentView) }

    func frame(of element: NSObject) -> CGRect? {
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        let screenFrame: CGRect
        if let accessible = element as? any NSAccessibilityProtocol {
            screenFrame = accessible.accessibilityFrame()
        } else if let value = element.value(forKey: "accessibilityFrame") as? NSValue {
            screenFrame = value.rectValue
        } else {
            return nil
        }
        return window.convertFromScreen(screenFrame)
    }

    func close() {
        NSApplication.shared.accessibilitySetValue(previousEnhancedUI, forAttribute: Self.enhancedUI)
        window.contentView = nil
        window.close()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private var accessibilityElements: [NSObject] {
        accessibilityElements(in: host)
    }

    private func accessibilityElements(in view: NSView) -> [NSObject] {
        view.subviews.flatMap(accessibilityElements(in:)) + accessibilityTree(view)
    }

    private func accessibilityTree(_ object: NSObject) -> [NSObject] {
        var result = [object]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [Any]
        else { return result }
        for child in children {
            if let child = child as? NSObject { result += accessibilityTree(child) }
        }
        return result
    }

    private func accessibilityString(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}

private extension CGRect {
    func isContained(in other: CGRect) -> Bool {
        minX >= other.minX - 1 && maxX <= other.maxX + 1 && minY >= other.minY - 1 && maxY <= other.maxY + 1
    }
}
