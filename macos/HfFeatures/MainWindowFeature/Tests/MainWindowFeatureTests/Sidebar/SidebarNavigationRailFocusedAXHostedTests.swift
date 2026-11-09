import AppKit
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - RailAppearanceCountingViewModel

/// A bounded, test-only `SidebarViewModel` that counts `didSelectAppearance` calls: every member
/// the rail reads stays a stored value, everything else is covered by the protocol's own
/// defaults. The product preview mock is untouched.
@MainActor
@Observable
final class RailAppearanceCountingViewModel: SidebarViewModel {
    /// Starts at `system`, so the focused menu marks exactly System as selected before selection.
    var appAppearance: AppAppearance = .system
    private(set) var appearanceChangeCount = 0

    var sections: [SidebarSection] = []
    var selection: MonitorDestination?
    var listErrorMessage: String?
    var emptyStateMessage: String?
    var showsLoadingSkeleton = false
    var isConnected = true
    var connectionLine = "connected · harflow-ctl"
    var backendTabs: [BackendTab] = [.all]
    var selectedBackend = "all"
    var catalogUnavailableNote: String?
    var searchQuery = ""
    var needsYouBadge: NeedsYouBadge = .count(3, atLeast: false)

    func didSelectAppearance(_ appearance: AppAppearance) {
        appAppearance = appearance
        appearanceChangeCount += 1
    }

    func didAppear() {}
    func didDisappear() {}
    func didChangeSearchQuery(_ text: String) {}
    func didSelectBackendFilter(_ backend: String) {}
    func didSelect(_ destination: MonitorDestination?) { selection = destination }
    func didTapNewSession() {}
    func didToggleExpansion(taskID: String) {}
    func didPressMoveCommand(_ direction: MoveCommandDirection) {}
}

// MARK: - SidebarNavigationRailFocusedAXHostedTests

/// Focused collapsed-rail accessibility evidence for correction 3: every rail control carries an
/// explicit accessible name, and the appearance menu surfaces once as a named, enabled,
/// menu-role control. Its modern public show-menu action opens the native tracking loop, where
/// `SidebarRailMenuTrackingProbe` verifies the owned menu — exact visible choices and one
/// natively selected System choice — and selects Light through the item's public press action.
/// Actionability is proven by performing actions and observing their effects, never by
/// `responds(to:)` or the deprecated legacy action-name enumeration; BOOL action results are
/// read through the exact `@convention(c)` ABI, never through `perform` (which would misread the
/// scalar as an object). The opened menu the assertions work against is the tracking menu's
/// public notification and its owned native items, never an assumed popup window topology.
@MainActor
@Suite(.serialized)
struct SidebarNavigationRailFocusedAXHostedTests {
    @Test
    func givenCollapsedRail_whenHosted_thenEveryRailControlCarriesAnExplicitName() async throws {
        // given — the production rail over a counting VM whose runtime is ready and 3 items pend.
        let fixture = hostRail()
        defer { fixture.teardown() }

        // when — native layout and accessibility bridging settle in the mounted window.
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            fixture.host.displayIfNeeded()
            return tree(fixture.window).contains { matches($0, title: "Expand sidebar") }
        }

        // then — explicit labels cover every rail control; help text never stands alone.
        for title in ["Expand sidebar", "New task", "Needs you, 3 pending", "Workflows",
                      "Resources", "Statistics", "Settings", "Change appearance"] {
            #expect(tree(fixture.window).contains { matches($0, title: title) },
                    "Missing rail accessible name: \(title)")
        }
    }

    @Test
    func givenCollapsedRail_whenAppearanceMenuDrivenThroughPublicAX_thenSelectsLightWithExactlyOneChange() async throws {
        // given — one named, enabled, menu-role appearance control is the rail's only action owner.
        let fixture = hostRail()
        defer { fixture.teardown() }
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            fixture.host.displayIfNeeded()
            return tree(fixture.window).contains { matches($0, title: "Change appearance") }
        }
        let namedAppearanceControls = tree(fixture.window).filter { matches($0, title: "Change appearance") }
        #expect(namedAppearanceControls.count == 1,
                "The appearance menu must appear exactly once as the rail's single appearance action owner.")
        let menu = try #require(namedAppearanceControls.first)
        let menuRole = try #require(role(of: menu), "The appearance control must report an accessibility role.")
        #expect(["AXMenuButton", "AXPopUpButton"].contains(menuRole),
                "The appearance control must report a menu role, got \(menuRole).")
        #expect(isEnabled(menu), "The appearance control must be enabled.")
        // The legacy action-name enumeration is deprecated and may remain empty for a modern
        // SwiftUI element. The modern protocol action and its effect are tested directly.
        #expect(selectorAllowed(menu, "accessibilityPerformShowMenu") == true)

        // when — the probe is armed first, then the public show-menu action fires on the main
        // actor. The native menu's tracking loop then runs on the main run loop; the probe's
        // observer and timer callbacks execute inside it (.eventTracking), select Light through
        // the item's public press action, close the owned menu and let the pumped run loop return.
        let probe = SidebarRailMenuTrackingProbe(viewModel: fixture.viewModel)
        probe.arm(deadline: 5)
        defer { probe.finish() }
        captureMenuEvidence(menu, fixture: fixture, stage: "before-show")
        let opened = axAction(menu, selectorName: "accessibilityPerformShowMenu")
        #expect(opened, "The modern public show-menu action must succeed.")
        captureMenuEvidence(menu, fixture: fixture, stage: "after-show", result: opened)
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            return probe.settled
        }
        await waitUntil(timeout: 5) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            return fixture.viewModel.appAppearance == .light
        }

        // then — exactly one owned native menu tracked, with exactly the three visible,
        // non-separator choices and System natively selected before Light was pressed.
        #expect(probe.acceptedTrackingCount == 1,
                "Menu tracking must begin exactly once, got \(probe.acceptedTrackingCount).")
        #expect(!probe.sawAmbiguousTrackingMenu, "A second tracking menu must never be accepted while armed.")
        #expect(probe.ownedMenu != nil, "The tracking notification must deliver the owned native menu.")
        #expect(probe.choicesValid,
                "The owned menu must expose exactly System/Light/Dark as its visible non-separator items.")
        #expect(probe.ownedIdentityValid, "Every chosen item must belong to the owned menu (item.menu === ownedMenu).")
        #expect(probe.initialStateValid, "Exactly one choice must be natively selected before pressing: System.")
        #expect(probe.didAttemptLightPress, "The probe must reach the Light item's actual public AX readiness.")

        // and — the real public press selected Light through the menu's single action owner.
        // AppKit returned false in the measured case while delivering the action after
        // tracking ended. Keep that acknowledgement in diagnostics; actual selection and the
        // exact callback count below establish the accessible operation's semantic result.
        #expect(probe.lightPressReturn != nil, "The one public AX invocation must return and be recorded.")
        #expect(fixture.viewModel.appAppearance == .light, "The public AX choice press must select Light.")
        #expect(fixture.viewModel.appearanceChangeCount == 1,
                "Selecting Light must change the appearance exactly once, got \(fixture.viewModel.appearanceChangeCount).")

        // and — the bounded probe settled inside its own deadline with no recorded failure.
        #expect(!probe.expired, "The probe must settle strictly inside its own 5 second deadline.")
        #expect(probe.failure == nil, "The probe must record no bounded failure, got \(probe.failure ?? "none").")
    }

    // MARK: - Fixture

    @MainActor
    private struct RailFixture {
        let window: NSWindow
        let host: NSView
        let viewModel: RailAppearanceCountingViewModel
        let enhanced: NSAccessibility.Attribute
        let previousEnhanced: Any?

        /// Closes only this fixture's own hosted window and restores the enhanced-user-interface
        /// value; menus are cancelled exclusively through the probe's owned menu, never globally.
        func teardown() {
            window.contentViewController = nil
            window.close()
            NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
        }
    }

    private func hostRail() -> RailFixture {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let viewModel = RailAppearanceCountingViewModel()
        let controller = NSHostingController(rootView: SidebarNavigationRail(viewModel, expand: {}))
        controller.sceneBridgingOptions = .all
        let host = controller.view
        let size = NSSize(width: 120, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFront(nil)
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        return RailFixture(window: window, host: host, viewModel: viewModel,
                           enhanced: enhanced, previousEnhanced: previousEnhanced)
    }

    // MARK: - Public AX probing

    private func tree(_ root: NSObject) -> [NSObject] {
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
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
            accessibilityString(object, key) == title
        }
    }

    private func role(of object: NSObject) -> String? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityRole()?.rawValue }
        let selector = NSSelectorFromString("accessibilityRole")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func selectorAllowed(_ object: NSObject, _ actionName: String) -> Bool? {
        let action = NSSelectorFromString(actionName)
        if let accessible = object as? any NSAccessibilityProtocol {
            return accessible.isAccessibilitySelectorAllowed(action)
        }
        let selector = NSSelectorFromString("isAccessibilitySelectorAllowed:")
        guard object.responds(to: selector) else { return nil }
        typealias Allowed = @convention(c) (AnyObject, Selector, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Allowed.self)
        return implementation(object, selector, action)
    }

    // MARK: - Bounded menu diagnostics

    /// The show-menu element's own public AX state, before and after the public action — legacy
    /// permitted actions and results included; the empty legacy action-name enumeration is
    /// recorded but never treated as an admission contract. Bounded, same capture directory.
    private func captureMenuEvidence(_ menu: NSObject, fixture: RailFixture, stage: String, result: Bool? = nil) {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        var payload: [String: Any] = [
            "stage": stage, "type": String(describing: type(of: menu)),
            "protocolConformance": menu is any NSAccessibilityProtocol,
            "enabled": isEnabled(menu), "windowVisible": fixture.window.isVisible,
            "nodes": (tree(menu) + tree(fixture.window)).prefix(128).map(menuNodeEvidence)
        ]
        payload["legacyActionNames"] = actionNames(menu) ?? NSNull()
        payload["allowedShowMenu"] = selectorAllowed(menu, "accessibilityPerformShowMenu") ?? NSNull()
        payload["allowedPress"] = selectorAllowed(menu, "accessibilityPerformPress") ?? NSNull()
        payload["actionResult"] = result ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("rail-menu-\(stage).json"))
    }

    private func menuNodeEvidence(_ object: NSObject) -> [String: Any] {
        var value: [String: Any] = ["type": String(describing: type(of: object))]
        value["role"] = role(of: object) ?? NSNull()
        value["label"] = accessibilityString(object, "accessibilityLabel") ?? NSNull()
        value["title"] = accessibilityString(object, "accessibilityTitle") ?? NSNull()
        value["legacyActions"] = actionNames(object) ?? NSNull()
        return value
    }

    private func actionNames(_ object: NSObject) -> [String]? {
        let selector = NSSelectorFromString("accessibilityActionNames")
        guard object.responds(to: selector),
              let names = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return nil }
        return names.compactMap { $0 as? String }
    }

    private func isEnabled(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return false }
        return object.value(forKey: "accessibilityEnabled") as? Bool == true
    }

    private func accessibilityString(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}

// MARK: - Guarded BOOL action ABI

/// `perform` would misread a scalar BOOL return as an object pointer, so the IMP is bitcast to
/// its exact `@convention(c)` type instead. AppKit accessibility is always invoked on the main
/// actor; the ShowMenu result is BOOL, read exactly.
@MainActor
private func axAction(_ object: NSObject, selectorName: String) -> Bool {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return false }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    let implementation = unsafeBitCast(object.method(for: selector), to: Press.self)
    return implementation(object, selector)
}
