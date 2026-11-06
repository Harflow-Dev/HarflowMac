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
    private nonisolated static let states: [RuntimeSetupState] = [
        .checking,
        .installationRequired(installedVersion: nil, requiredVersion: "0.0.11"),
        .installationRequired(installedVersion: "0.0.9", requiredVersion: "0.0.11"),
        .installing,
        .updating(installedVersion: "0.0.9", requiredVersion: "0.0.11"),
        .failed("Synthetic installation failure."),
        .updateFailed(message: "Synthetic update failure.", installedVersion: "0.0.9", requiredVersion: "0.0.11")
    ]

    @Test(arguments: states, [NSAppearance.Name.aqua, .darkAqua])
    func givenRuntimeSetupState_whenMountedAtApprovedSizes_thenCorrectStateAndExplicitActionRemainWithinContent(
        state: RuntimeSetupState, appearanceName: NSAppearance.Name
    ) async throws {
        // given — approved HarflowDesign 5b37a3d runtime boards, with synthetic cached state only.
        let coordinator = MainWindowNavigationCoordinatorMock(runtimeIsReady: false, runtimeSetupState: state)
        let fixture = MainWindowRuntimeSetupFixture(coordinator: coordinator, appearanceName: appearanceName)
        defer { fixture.close() }
        let expected = expectedPresentation(state)

        // when — observing the title ensures the main pane, rather than the sidebar, has rendered.
        await fixture.waitForTitle(expected.title)
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
            fixture.window.setContentSize(size)
            await fixture.waitForSize(size)

            // then — loading never initiates installation, update or retry automatically.
            try fixture.expectSplitViewWithinContent()
            #expect(fixture.text(identifier: "runtimeSetup.welcomeTitle") == expected.title)
            #expect(fixture.text(identifier: "runtimeSetup.action") == expected.action)
            #expect(fixture.text(identifier: expected.failure ? "runtimeSetup.error" : "runtimeSetup.welcomeBody") == state.detail)
            #expect((fixture.element(identifier: "runtimeSetup.error") != nil) == expected.failure)
            #expect(coordinator.sidebarViewModel.runtimeSetupTapCount == 0)
            #expect(coordinator.runtimeSetupState == state)
            if state.isBusy { #expect(fixture.containsText(state.title)) }
        }
        if expected.action != nil {
            let action = try #require(fixture.element(identifier: "runtimeSetup.action"))
            let press = NSSelectorFromString("accessibilityPerformPress")
            #expect(action.responds(to: press))
            _ = action.perform(press)
            await waitUntil { coordinator.sidebarViewModel.runtimeSetupTapCount == 1 }
            #expect(coordinator.sidebarViewModel.runtimeSetupTapCount == 1)
            #expect(coordinator.runtimeSetupState == state)
        }
    }

    @Test func givenCheckingRuntime_whenInstallationBecomesRequired_thenMainPaneUpdatesWithoutStartingSetup() async throws {
        // given
        let coordinator = MainWindowNavigationCoordinatorMock(runtimeIsReady: false, runtimeSetupState: .checking)
        let fixture = MainWindowRuntimeSetupFixture(coordinator: coordinator, appearanceName: .aqua)
        defer { fixture.close() }
        await fixture.waitForTitle("Checking Harflow runtime")
        #expect(fixture.element(identifier: "runtimeSetup.action") == nil)

        // when
        coordinator.runtimeSetupState = .installationRequired(installedVersion: nil, requiredVersion: "0.0.11")
        await fixture.waitForTitle("Set up Harflow")

        // then
        #expect(fixture.text(identifier: "runtimeSetup.action") == "Install runtime")
        #expect(coordinator.sidebarViewModel.runtimeSetupTapCount == 0)
        try fixture.expectSplitViewWithinContent()
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenLongFailureDiagnostic_whenResized_thenSplitViewStaysWithinWindowContent(_ appearanceName: NSAppearance.Name) async throws {
        // given
        let message = String(repeating: "The managed runtime could not be prepared. ", count: 60)
        let coordinator = MainWindowNavigationCoordinatorMock(runtimeIsReady: false, runtimeSetupState: .failed(message))
        let fixture = MainWindowRuntimeSetupFixture(coordinator: coordinator, appearanceName: appearanceName)
        defer { fixture.close() }

        // when
        await fixture.waitForTitle("Setup could not finish")
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
            fixture.window.setContentSize(size)
            await fixture.waitForSize(size)

            // then
            #expect(fixture.text(identifier: "runtimeSetup.error") == message)
            #expect(fixture.text(identifier: "runtimeSetup.action") == "Retry setup")
            #expect(coordinator.sidebarViewModel.runtimeSetupTapCount == 0)
            try fixture.expectSplitViewWithinContent()
        }
    }

    private func expectedPresentation(_ state: RuntimeSetupState) -> (title: String, action: String?, failure: Bool) {
        switch state {
        case .checking: ("Checking Harflow runtime", nil, false)
        case .installationRequired(let installed, _):
            installed == nil ? ("Set up Harflow", "Install runtime", false) : ("Update required", "Update runtime", false)
        case .installing: ("Installing runtime", nil, false)
        case .updating: ("Updating runtime", nil, false)
        case .failed: ("Setup could not finish", "Retry setup", true)
        case .updateFailed: ("Update could not finish", "Retry setup", true)
        case .ready: ("Runtime ready", nil, false)
        }
    }

}

// MARK: - MainWindowRuntimeSetupFixture

@MainActor private final class MainWindowRuntimeSetupFixture {
    let window: NSWindow
    let host: NSView
    private let controller: NSHostingController<AnyView>

    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousEnhancedUI: Bool

    init(coordinator: MainWindowNavigationCoordinatorMock, appearanceName: NSAppearance.Name) {
        _ = NSApplication.shared
        self.previousEnhancedUI = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI) as? Bool ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator)))
        controller.sceneBridgingOptions = .all
        self.controller = controller
        self.host = controller.view
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

    func waitForTitle(_ title: String) async {
        await waitUntil(timeout: 5) {
            self.host.layoutSubtreeIfNeeded()
            return self.splitView != nil && self.text(identifier: "runtimeSetup.welcomeTitle") == title
        }
    }

    func waitForSize(_ size: NSSize) async {
        await waitUntil(timeout: 5) {
            self.host.layoutSubtreeIfNeeded()
            guard let split = self.splitView else { return false }
            let frame = split.convert(split.bounds, to: self.host)
            return abs(self.host.bounds.width - size.width) < 1
                && abs(self.host.bounds.height - size.height) < 1
                && frame.height <= self.host.bounds.height + 1
                && frame.minY >= self.host.bounds.minY - 1
                && frame.maxY <= self.host.bounds.maxY + 1
        }
    }

    func expectSplitViewWithinContent(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let split = try #require(splitView, sourceLocation: sourceLocation)
        let content = try #require(window.contentView, sourceLocation: sourceLocation)
        let frame = split.convert(split.bounds, to: content)
        let bounds = content.bounds
        #expect(frame.width <= bounds.width + 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.minX >= bounds.minX - 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.maxX <= bounds.maxX + 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.height <= bounds.height + 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.minY >= bounds.minY - 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
        #expect(frame.maxY <= bounds.maxY + 1, "split=\(frame) content=\(bounds)", sourceLocation: sourceLocation)
    }

    func element(identifier: String) -> NSObject? {
        accessibilityTree(host).first { accessibilityString($0, "accessibilityIdentifier") == identifier }
    }

    func containsText(_ text: String) -> Bool {
        accessibilityTree(host).contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { accessibilityString(object, $0) == text }
        }
    }

    func text(identifier: String) -> String? {
        guard let object = element(identifier: identifier) else { return nil }
        return accessibilityString(object, "accessibilityLabel") ?? accessibilityString(object, "accessibilityTitle")
            ?? accessibilityString(object, "accessibilityValue")
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
