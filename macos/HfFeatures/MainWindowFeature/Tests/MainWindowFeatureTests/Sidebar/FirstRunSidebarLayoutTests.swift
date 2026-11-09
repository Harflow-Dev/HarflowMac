import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct FirstRunSidebarLayoutTests {
    private static let gateText = "Runtime setup required before creating or loading work."
    private static let catalogNote = "The backend catalog couldn't be read; filters show loaded history only."
    private nonisolated static let notReadyStates: [RuntimeSetupState] = [
        .checking,
        .installationRequired(installedVersion: nil, requiredVersion: "0.0.2"),
        .installationRequired(installedVersion: "0.0.1", requiredVersion: "0.0.2"),
        .installing,
        .updating(installedVersion: "0.0.1", requiredVersion: "0.0.2"),
        .failed("The managed runtime could not be prepared."),
        .updateFailed(message: "The update could not be applied.", installedVersion: "0.0.1", requiredVersion: "0.0.2")
    ]

    @Test(arguments: notReadyStates)
    func givenNonReadyRuntimeState_whenSidebarMounts_thenOnlyTitleRowGateLineAndFooterRender(
        _ state: RuntimeSetupState
    ) async throws {
        // given — store attention and the catalog note are forced on to prove they stay hidden.
        let viewModel = SidebarViewModelMock(catalogUnavailableNote: Self.catalogNote, runtimeSetupState: state)
        viewModel.storeNeedsAttention = true
        let fixture = try SidebarFirstRunWindowFixture(viewModel: viewModel, appearanceName: .aqua)
        defer { fixture.close() }

        // when
        await fixture.waitForGate()

        // then
        try fixture.expectGateLayout()
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua], [NSSize(width: 1000, height: 620), NSSize(width: 1200, height: 740)])
    func givenRuntimeSetupRequired_whenSidebarMountsAtEachSize_thenGateLayoutHoldsInEveryAppearanceAndSize(
        _ appearanceName: NSAppearance.Name, _ size: NSSize
    ) async throws {
        // given
        let state = RuntimeSetupState.installationRequired(installedVersion: nil, requiredVersion: "0.0.2")
        let viewModel = SidebarViewModelMock(catalogUnavailableNote: Self.catalogNote, runtimeSetupState: state)
        viewModel.storeNeedsAttention = true
        let fixture = try SidebarFirstRunWindowFixture(viewModel: viewModel, appearanceName: appearanceName)
        defer { fixture.close() }

        // when
        fixture.window.setContentSize(size)
        await fixture.waitForGate()

        // then
        try fixture.expectGateLayout()
    }

    @Test func givenRuntimeSetupRequired_whenRuntimeBecomesReady_thenSidebarReturnsToTaskList() async throws {
        // given
        let viewModel = SidebarViewModelMock(
            runtimeSetupState: .installationRequired(installedVersion: nil, requiredVersion: "0.0.2")
        )
        viewModel.storeNeedsAttention = true
        let fixture = try SidebarFirstRunWindowFixture(viewModel: viewModel, appearanceName: .aqua)
        defer { fixture.close() }
        await fixture.waitForGate()
        #expect(sidebarFixtureOutline(in: fixture.host) == nil)
        #expect(fixture.count(identifier: "sidebar-store-attention") == 0)

        // when
        viewModel.runtimeSetupState = .ready
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            return sidebarFixtureOutline(in: fixture.host) != nil
        }
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            fixture.host.layoutSubtreeIfNeeded()
            return fixture.count(identifier: "sidebar-store-attention") > 0
        }

        // then — the link is the positive control for the not-ready absence check.
        #expect(fixture.count(identifier: "sidebar-store-attention") > 0)
        #expect(fixture.count(identifier: "sidebar-setup-gate") == 0)
        #expect(fixture.element(label: Self.gateText) == nil)
        #expect(sidebarFixtureOutline(in: fixture.host) != nil)
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

    func waitForGate() async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            return element(identifier: "sidebar-setup-gate") != nil && element(label: "Settings") != nil
        }
    }

    func count(identifier: String) -> Int {
        accessibilityElements.filter { accessibilityString($0, "accessibilityIdentifier") == identifier }.count
    }

    /// The not-ready sidebar: the title row topmost and clear of the toolbar inset, the exact gate
    /// line 24 pt below it, the footer below the gate, and nothing else.
    func expectGateLayout(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let gateText = "Runtime setup required before creating or loading work."
        let gate = try #require(element(identifier: "sidebar-setup-gate"), sourceLocation: sourceLocation)
        let title = try #require(element(label: "Harflow"), sourceLocation: sourceLocation)
        let collapse = try #require(element(label: "Collapse sidebar"), sourceLocation: sourceLocation)
        let footer = try #require(element(label: "Settings"), sourceLocation: sourceLocation)
        let contentLayout = window.contentLayoutRect
        let gateFrame = try #require(frame(of: gate), sourceLocation: sourceLocation)
        let titleFrame = try #require(frame(of: title), sourceLocation: sourceLocation)
        let collapseFrame = try #require(frame(of: collapse), sourceLocation: sourceLocation)
        let footerFrame = try #require(frame(of: footer), sourceLocation: sourceLocation)

        #expect(accessibilityString(gate, "accessibilityLabel") == gateText
            || accessibilityString(gate, "accessibilityValue") == gateText, sourceLocation: sourceLocation)
        // Window coordinates grow upward. The title row sits under the toolbar inset, above the gate.
        #expect(titleFrame.maxY <= contentLayout.maxY + 1, "Title row must clear the traffic-light inset", sourceLocation: sourceLocation)
        #expect(titleFrame.isContained(in: contentLayout), sourceLocation: sourceLocation)
        #expect(titleFrame.minY >= gateFrame.maxY, sourceLocation: sourceLocation)
        #expect(gateFrame.minY >= footerFrame.maxY - 1, sourceLocation: sourceLocation)
        #expect(gateFrame.isContained(in: contentLayout), sourceLocation: sourceLocation)
        #expect(footerFrame.isContained(in: contentLayout), sourceLocation: sourceLocation)
        // 24 pt from the bottom of the title row (the lower of its two controls) to the gate text.
        let rowBottom = min(titleFrame.minY, collapseFrame.minY)
        let gap = rowBottom - gateFrame.maxY
        #expect(abs(gap - 24) <= 1.5, "Measured title-row to gate gap \(gap) pt, expected 24", sourceLocation: sourceLocation)

        for identifier in ["runtimeSetup.card", "runtimeSetup.title", "runtimeSetup.action", "runtimeSetup.error",
                           "sidebar-install-notice", "sidebar-store-attention", "sidebar-unified"] {
            #expect(count(identifier: identifier) == 0, "\(identifier) must not render", sourceLocation: sourceLocation)
        }
        for label in ["New task", "Prepare Harflow", "Setup did not finish", "Task store needs attention",
                      "The backend catalog couldn't be read; filters show loaded history only."] {
            #expect(element(label: label) == nil, "\"\(label)\" must not render", sourceLocation: sourceLocation)
        }
        #expect(sidebarFixtureOutline(in: host) == nil, sourceLocation: sourceLocation)
        #expect(button(matching: "Install required components") == nil, sourceLocation: sourceLocation)
        #expect(textField(matchingPlaceholder: "Search loaded history") == nil, sourceLocation: sourceLocation)
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

    func element(identifier: String) -> NSObject? {
        accessibilityElements.first { accessibilityString($0, "accessibilityIdentifier") == identifier }
    }

    func button(matching value: String) -> NSButton? {
        descendants.compactMap { $0 as? NSButton }.first { $0.title == value }
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
