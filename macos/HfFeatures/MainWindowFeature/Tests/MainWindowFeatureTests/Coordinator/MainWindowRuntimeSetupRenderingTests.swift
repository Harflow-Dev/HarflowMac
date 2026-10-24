import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - MainWindowRuntimeSetupRenderingTests

/// Geometry regressions for the main window while the managed runtime is not ready.
///
/// A `.fixedSize(vertical:)` text in the detail pane made `NavigationSplitView` measure the column
/// with a character-per-line height, so the split view grew far taller than the window and was
/// centered, pushing the sidebar's setup card and footer out of view.
@MainActor @Suite(.serialized) struct MainWindowRuntimeSetupRenderingTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenCheckingThenInstallationRequired_whenMainWindowMounted_thenSplitViewStaysWithinWindowContent(
        _ appearanceName: NSAppearance.Name
    ) async throws {
        // given
        let coordinator = MainWindowNavigationCoordinatorMock(runtimeIsReady: false, runtimeSetupState: .checking)
        let fixture = MainWindowRuntimeSetupFixture(coordinator: coordinator, appearanceName: appearanceName)
        defer { fixture.close() }
        await fixture.waitForSplitView()
        try fixture.expectSplitViewWithinContent()
        #expect(fixture.element(identifier: "runtimeSetup.action") == nil)

        // when
        coordinator.runtimeSetupState = .installationRequired(installedVersion: nil, requiredVersion: "0.0.2")
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            return fixture.element(identifier: "runtimeSetup.action") != nil
        }
        fixture.settle()

        // then
        #expect(fixture.element(identifier: "runtimeSetup.action") != nil)
        try fixture.expectSplitViewWithinContent()
    }

    @Test func givenLongFailureDiagnostic_whenMainWindowMounted_thenSplitViewStaysWithinWindowContent() async throws {
        // given
        let message = String(repeating: "The managed runtime could not be prepared. ", count: 60)
        let coordinator = MainWindowNavigationCoordinatorMock(runtimeIsReady: false, runtimeSetupState: .failed(message))
        let fixture = MainWindowRuntimeSetupFixture(coordinator: coordinator, appearanceName: .aqua)
        defer { fixture.close() }

        // when
        await fixture.waitForSplitView()
        fixture.settle()

        // then
        #expect(fixture.element(identifier: "runtimeSetup.error") != nil)
        try fixture.expectSplitViewWithinContent()
    }

    @Test func givenInstallationRequired_whenWindowResizedToMinimumAndBack_thenSplitViewStaysWithinWindowContent() async throws {
        // given
        let coordinator = MainWindowNavigationCoordinatorMock(
            runtimeIsReady: false,
            runtimeSetupState: .installationRequired(installedVersion: nil, requiredVersion: "0.0.2")
        )
        let fixture = MainWindowRuntimeSetupFixture(coordinator: coordinator, appearanceName: .aqua)
        defer { fixture.close() }
        await fixture.waitForSplitView()

        // when / then
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1200, height: 740)] {
            fixture.window.setContentSize(size)
            fixture.settle()
            try fixture.expectSplitViewWithinContent()
        }
    }
}

// MARK: - MainWindowRuntimeSetupFixture

@MainActor private final class MainWindowRuntimeSetupFixture {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousEnhancedUI: Bool

    init(coordinator: MainWindowNavigationCoordinatorMock, appearanceName: NSAppearance.Name) {
        _ = NSApplication.shared
        self.previousEnhancedUI = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI) as? Bool ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        self.host = NSHostingView(rootView: AnyView(MainWindowNavigationView(coordinator)))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "runtime-setup-rendering")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    var splitView: NSSplitView? { descendants(of: host).compactMap { $0 as? NSSplitView }.first }

    func waitForSplitView() async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            self.host.layoutSubtreeIfNeeded()
            return self.splitView != nil
        }
    }

    /// Lets pending SwiftUI/AppKit layout passes run, then lays out once more.
    func settle() {
        for _ in 0 ..< 5 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
    }

    func expectSplitViewWithinContent(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let split = try #require(splitView, sourceLocation: sourceLocation)
        let content = try #require(window.contentView, sourceLocation: sourceLocation)
        let frame = split.convert(split.bounds, to: content)
        let bounds = content.bounds
        #expect(frame.height <= bounds.height + 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.minY >= bounds.minY - 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.maxY <= bounds.maxY + 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
    }

    func element(identifier: String) -> NSObject? {
        accessibilityTree(host).first { accessibilityString($0, "accessibilityIdentifier") == identifier }
    }

    func close() {
        NSApplication.shared.accessibilitySetValue(previousEnhancedUI, forAttribute: Self.enhancedUI)
        window.contentView = nil
        window.close()
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private func accessibilityTree(_ object: NSObject) -> [NSObject] {
        var result = [object]
        if let view = object as? NSView { result += view.subviews.flatMap(accessibilityTree) }
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [Any]
        else { return result }
        for case let child as NSObject in children where !(child is NSView) { result += accessibilityTree(child) }
        return result
    }

    private func accessibilityString(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}
