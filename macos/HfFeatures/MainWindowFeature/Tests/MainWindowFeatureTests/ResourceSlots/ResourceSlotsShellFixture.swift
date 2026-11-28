import AppKit
import HfCommon
import HfTestUtilities
@testable import MainWindowFeature
import Observation
import SwiftUI

// MARK: - ResourceSlotsShellModel

/// Test-only resource slots model bound to the shipping shell's coordinator mock. It has the
/// same four synthetic rows, counters and presentation as `ResourceSlotsInteractionModel`, which
/// stays unchanged. Owners route to `.task(row)`. It authorizes a focus return only from
/// `returnFromOwner()`, which the mock's `onReturnToResourceSlots` hook calls, so there is
/// exactly one authorization per Back.
@MainActor @Observable
final class ResourceSlotsShellModel: ResourceSlotsViewModel {
    @ObservationIgnored weak var coordinator: MainWindowNavigationCoordinatorMock?
    @ObservationIgnored weak var evidence: ResourceSlotsShellEvidence?
    var presentation: ResourceSlotsPresentation
    let rowIDs: [String]
    let readingState = ResourceSlotsReadingState()
    var expandedResourceIDs: Set<String>
    var expandedBlockerIDs: Set<String> = []
    var appearances = 0
    var disappearances = 0
    var openedRows: [String] = []
    /// How many times the shell's Back item reached the coordinator's return hook.
    var returnCallbacks = 0

    init(coordinator: MainWindowNavigationCoordinatorMock, rowCount: Int = 4) {
        self.coordinator = coordinator
        let ids = (0 ..< rowCount).map { "native-owner-\($0)" }
        self.rowIDs = ids
        let group = ResourceSlotsGroup(
            id: "native-resource", title: "Native resource", capacitySummary: "Synthetic observed holdings",
            holderHeading: "Holders",
            holders: ids.map { id in
                ResourceSlotsOwner(id: id, title: id, ownerID: id, status: "Holding capacity", since: nil,
                                   detail: "Synthetic native interaction fixture", position: nil,
                                   action: .init(label: "Open workflow run", ownerID: id), blockers: nil)
            }, emptyHolderMessage: nil, waiterHeading: nil, waiters: [])
        self.expandedResourceIDs = [group.id]
        self.presentation = .init(state: .ready(summary: "Synthetic resource inventory", groups: [group]), qualifiers: [])
    }

    static func detailMarker(_ rowID: String) -> String { "Synthetic task owner destination " + rowID }
    static let detailControlIdentifier = "resource-slots-shell-detail-control"

    func actionLabel(_ id: String) -> String { "Open workflow run " + id }

    func didAppear() {
        appearances += 1
        readingState.setSelected(coordinator?.selection == .resourceSlots)
    }

    func didDisappear() { disappearances += 1 }
    func didTapRefresh() {}
    func didToggleResource(_ id: String) {
        readingState.cancelRestorationForUser()
        if !expandedResourceIDs.insert(id).inserted { expandedResourceIDs.remove(id) }
    }

    func didToggleBlockers(_ id: String) {
        if !expandedBlockerIDs.insert(id).inserted { expandedBlockerIDs.remove(id) }
    }

    func didOpenOwner(_ rowID: String) {
        guard rowIDs.contains(rowID), let coordinator else { return }
        evidence?.stamp("owner-route", rowID)
        readingState.prepareDeparture(ownerRowID: rowID)
        openedRows.append(rowID)
        coordinator.selection = .task(rowID)
        coordinator.resourceReturnAvailable = true
        selectionChanged()
    }

    /// The selection side effects the production `selection.didSet` has on the reading state.
    func selectionChanged() {
        guard let coordinator else { return }
        readingState.setSelected(coordinator.selection == .resourceSlots)
        if coordinator.selection != .resourceSlots, !coordinator.canReturnToResourceSlots {
            readingState.clearFocusReturn()
        }
    }

    /// Replays the production return order synchronously: authorize, select the screen, apply
    /// the selection side effects, then drop the return item.
    func returnFromOwner() {
        returnCallbacks += 1
        guard let coordinator, coordinator.canReturnToResourceSlots else {
            evidence?.stamp("return-refused", "no return available")
            return
        }
        evidence?.stamp("return-callback", "authorize")
        readingState.authorizeFocusReturn()
        evidence?.stamp("return-callback", "selection")
        coordinator.selection = .resourceSlots
        selectionChanged()
        evidence?.stamp("return-callback", "return item removed")
        coordinator.resourceReturnAvailable = false
        if !(coordinator.selection == .resourceSlots && readingState.hasAuthorizedFocusReturn) {
            readingState.clearFocusReturn()
        }
    }
}

// MARK: - ResourceSlotsShellFixture

/// The production shell (`MainWindowNavigationView`, real `NSToolbar`) hosting the resource slots
/// screen, with the sidebar collapsed unless the variant asks for it expanded, and optionally a
/// focusable control in the synthetic task detail. Modelled on `TopBarIntegratedFixture`.
@MainActor
final class ResourceSlotsShellFixture: ResourceSlotsNativeHosting {
    static let backTitle = "Back to resource slots"
    static let size = NSSize(width: 1280, height: 800)

    let coordinator = MainWindowNavigationCoordinatorMock()
    let model: ResourceSlotsShellModel
    let window: NSWindow
    private let controller: NSHostingController<AnyView>
    private let scratch = ScratchDefaults(label: "ResourceSlotsShell")
    private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousEnhanced: Any?
    private let previousPolicy: NSApplication.ActivationPolicy
    private(set) var axEnhancedWasEnabled = false

    init(sidebarCollapsed: Bool = true, detailControl: Bool = false) {
        _ = NSApplication.shared
        self.previousEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        self.axEnhancedWasEnabled = true
        self.previousPolicy = NSApp.activationPolicy()
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsShellModel(coordinator: coordinator)
        self.model = model
        coordinator.resourceSlotsBuilder = { AnyView(ResourceSlotsView(model)) }
        coordinator.taskDetailBuilder = { id in
            AnyView(
                VStack(spacing: 12) {
                    Text(ResourceSlotsShellModel.detailMarker(id))
                    if detailControl {
                        Button("Detail action") {}
                            .accessibilityIdentifier(ResourceSlotsShellModel.detailControlIdentifier)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        coordinator.onReturnToResourceSlots = { [weak model] in model?.returnFromOwner() }
        let root = MainWindowNavigationView(coordinator, sidebarCollapsed: sidebarCollapsed)
            .defaultAppStorage(scratch.defaults)
            .environment(\.hfReduceMotionOverride, true)
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sceneBridgingOptions = .all
        self.controller = controller
        self.window = M04ToolbarEvidence.makeWindow(controller, size: Self.size)
        window.appearance = NSAppearance(named: .aqua)
    }

    func close() {
        coordinator.resourceSlotsBuilder = nil
        coordinator.taskDetailBuilder = nil
        coordinator.onReturnToResourceSlots = nil
        window.contentViewController = nil
        window.close()
        NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
        NSApp.setActivationPolicy(previousPolicy)
        scratch.remove()
    }

    // MARK: ResourceSlotsNativeHosting

    var contentRoot: NSView { window.contentView ?? controller.view }
    var descendants: [NSView] { views(contentRoot) }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    func elements(in object: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [object] }
        return [object] + children.flatMap { elements(in: $0) }
    }

    func string(_ object: NSObject, _ property: String) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    func element(_ label: String) -> NSObject? {
        descendants.flatMap { elements(in: $0) }.first { matches($0, label) }
    }

    func frame(_ object: NSObject) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return window.convertFromScreen(accessible.accessibilityFrame()) }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue
        else { return nil }
        return window.convertFromScreen(value.rectValue)
    }

    func matches(_ object: NSObject, _ label: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityIdentifier"]
            .contains { string(object, $0) == label }
    }

    // MARK: Toolbar

    /// Bounded walk over an object's accessibility children and subviews.
    func axTree(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        while let next = queue.popLast(), result.count < 3000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: kids)
            }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    /// Toolbar items whose view renders an `AXButton` titled "Back to resource slots", with those buttons.
    func backItems() -> [(item: NSToolbarItem, buttons: [NSObject])] {
        (window.toolbar?.items ?? []).compactMap { item in
            guard let view = item.view else { return nil }
            let buttons = axTree(view).filter {
                string($0, "accessibilityRole") == "AXButton"
                    && [string($0, "accessibilityLabel"), string($0, "accessibilityTitle")].contains(Self.backTitle)
            }
            return buttons.isEmpty ? nil : (item, buttons)
        }
    }

    /// Accessibility buttons drawn by the toolbar, used to size the Tab budget.
    func toolbarButtonCount() -> Int {
        (window.toolbar?.items ?? []).reduce(0) { total, item in
            guard let view = item.view else { return total }
            return total + axTree(view).filter { string($0, "accessibilityRole") == "AXButton" }.count
        }
    }
}
