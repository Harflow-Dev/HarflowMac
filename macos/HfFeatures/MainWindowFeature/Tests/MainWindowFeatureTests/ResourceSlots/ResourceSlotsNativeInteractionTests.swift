import AppKit
import HfCommon
import HfCommonTestMock
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

/// These checks require the opt-in native runner and an unlocked foreground window server.
extension ActivityFeedApprovalHostedTests {
    @Test(arguments: [1, 4])
    func givenDeepResourceOwner_whenOpeningAndReturning_thenNativeOffsetAndKeyboardFocusAreRestored(_ groupCount: Int) async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: groupCount == 1 ? 120 : 60, groupCount: groupCount)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: ResourceSlotsInteractionViewport.size, appearance: .light)
        fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
        let previousPolicy = NSApp.activationPolicy()
        let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "owner-return-\(groupCount)-groups")
        model.trace = trace
        var testBodyCompleted = false
        defer { trace.finish(testBodyCompleted: testBodyCompleted); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        try await resourceInteractionQualifyKeyboardHost(fixture, model)
        await fixture.settle { resourceInteractionScroll(fixture) != nil && model.appearances == 1 }
        let departure = try await resourceInteractionPrepareReading(fixture, model: model, groupCount: groupCount, trace: trace)
        try await resourceInteractionRouteAndBack(fixture, model: model, departure: departure, trace: trace)
        try await resourceInteractionVerifyReturn(fixture, model: model, departure: departure, trace: trace)
        coordinator.selection = .statistics
        #expect(!coordinator.canReturnToResourceSlots)
        testBodyCompleted = true
    }

    @Test func givenResourceHeader_whenNativePressAndKeyboardToggle_thenOneStatefulButtonPreservesTheFullHeaderHitArea() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: ResourceSlotsInteractionViewport.size, appearance: .light)
        fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
        let originalWindowSize = fixture.window.frame.size
        let previousPolicy = NSApp.activationPolicy()
        let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "native-header-button")
        model.trace = trace
        var testBodyCompleted = false
        defer { trace.finish(testBodyCompleted: testBodyCompleted); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        try await resourceInteractionQualifyKeyboardHost(fixture, model)
        try resourceInteractionRequireViewport(fixture, expectedWindowSize: originalWindowSize)
        let initialClip = try #require(resourceSlotsAttachedScroll(fixture))
        let originalClipSize = initialClip.clip.bounds.size
        await fixture.settle { resourceInteractionHeaderButtons(fixture).count == 1 }
        trace.surveyDisclosure(expandedModel: true)
        let expanded = try resourceInteractionRequireHeader(fixture, value: "Expanded")
        let initialState = try #require(resourceSlotsNativeHeaderState(expanded))
        trace.mark("header-state-representation", details: ["attribute": initialState.attribute, "kind": initialState.kind])

        // when: invoke the real native button Press and inspect both independent model and AX state.
        try #require(fixture.press(expanded))
        await fixture.settle { !model.expandedResourceIDs.contains("native-resource") }
        try #require(!model.expandedResourceIDs.contains("native-resource"))
        trace.surveyDisclosure(expandedModel: false)
        let collapsed = try resourceInteractionRequireHeader(fixture, value: "Collapsed")
        let collapsedState = try #require(resourceSlotsNativeHeaderState(collapsed))
        #expect(collapsedState.attribute == initialState.attribute && collapsedState.kind == initialState.kind)
        trace.mark("header-native-press-collapsed")
        try resourceInteractionRequireViewport(fixture, expectedClipSize: originalClipSize, expectedWindowSize: originalWindowSize)

        // then: AX-requested focus and real Space reopen the same control — but only under the
        // platform's keyboard focus policy. With Full Keyboard Access off, macOS ignores a
        // modern `setAccessibilityFocused` request on a SwiftUI button (measured: the focused
        // element stays nil), so the keyboard steps can only run when the setting is on; with
        // it off the same control is reopened through its qualified native Press instead, and
        // the skip is recorded. Tab traversal is qualified separately either way.
        let fullKeyboardAccess = NSApp.isFullKeyboardAccessEnabled
        trace.mark("header-AX-requested-focus", details: ["provesTabTraversal": "false", "provesOwnerRestoration": "false",
                                                          "fullKeyboardAccess": String(fullKeyboardAccess)])
        if fullKeyboardAccess {
            resourceSlotsRequestNativeFocus(collapsed)
            await fixture.settle { resourceInteractionFocusedIdentifier(fixture) == "resource-slots-group-native-resource" }
            try resourceInteractionRequireActiveHost(fixture, model)
            try #require(resourceInteractionFocusedIdentifier(fixture) == "resource-slots-group-native-resource",
                         Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
            resourceInteractionSpace(fixture.window)
            await fixture.settle { model.expandedResourceIDs.contains("native-resource") }
            try #require(model.expandedResourceIDs.contains("native-resource"))
            trace.mark("header-keyboard-space-expanded")
        } else {
            // Platform policy, user decision: never change the user's keyboard setting. With
            // Full Keyboard Access off the AX-focus and real-Space steps are skipped and this
            // mark records that; the header's own state machine is still reopened through the
            // same qualified native Press path, never a fake keyboard pass.
            trace.mark("header-keyboard-step-skipped",
                       details: ["reason": "Full Keyboard Access off: macOS ignores AX focus requests for SwiftUI buttons"])
            try #require(fixture.press(collapsed))
            await fixture.settle { model.expandedResourceIDs.contains("native-resource") }
            try #require(model.expandedResourceIDs.contains("native-resource"))
        }
        trace.surveyDisclosure(expandedModel: true)
        let reopened = try resourceInteractionRequireHeader(fixture, value: "Expanded")
        let reopenedState = try #require(resourceSlotsNativeHeaderState(reopened))
        #expect(reopenedState == initialState)
        try await resourceInteractionVerifyHeaderHitArea(fixture, model: model, trace: trace)
        try resourceInteractionRequireViewport(fixture, expectedClipSize: originalClipSize, expectedWindowSize: originalWindowSize)
        testBodyCompleted = true
    }
}

@MainActor @Observable
final class ResourceSlotsInteractionModel: ResourceSlotsViewModel {
    let coordinator: MainWindowCoordinator
    var presentation: ResourceSlotsPresentation
    let rowIDs: [String]
    let rowsByGroup: [[String]]
    let readingState = ResourceSlotsReadingState()
    @ObservationIgnored var trace: ResourceSlotsNativeTrace?
    var expandedResourceIDs: Set<String>
    var expandedBlockerIDs: Set<String> = []
    var appearances = 0
    var disappearances = 0
    var openedRows: [String] = []

    init(coordinator: MainWindowCoordinator, rowCount: Int, groupCount: Int = 1) {
        self.coordinator = coordinator
        let groupedIDs = (0 ..< groupCount).map { group in
            (0 ..< rowCount).map { row in groupCount == 1 ? "native-owner-\(row)" : "native-owner-\(group)-\(row)" }
        }
        self.rowsByGroup = groupedIDs
        self.rowIDs = groupedIDs.flatMap(\.self)
        let groups = groupedIDs.enumerated().map { group, ids in
            ResourceSlotsGroup(id: group == 0 ? "native-resource" : "native-resource-\(group)",
                               title: group == 0 ? "Native resource" : "Native resource \(group)",
                               capacitySummary: "Synthetic observed holdings", holderHeading: "Holders",
                               holders: ids.map { id in
                                   ResourceSlotsOwner(id: id, title: id, ownerID: id, status: "Holding capacity", since: nil,
                                                      detail: "Synthetic native interaction fixture", position: nil,
                                                      action: .init(label: "Open workflow run", ownerID: id), blockers: nil)
                               }, emptyHolderMessage: nil, waiterHeading: nil, waiters: [])
        }
        self.expandedResourceIDs = Set(groups.map(\.id))
        self.presentation = .init(state: .ready(summary: "Synthetic resource inventory", groups: groups), qualifiers: [])
    }

    func returnToResourceSlots() {
        trace?.mark("exact-back-route")
        readingState.authorizeFocusReturn()
        coordinator.returnToResourceSlots()
    }

    func selectionChanged() {
        readingState.setSelected(coordinator.selection == .resourceSlots)
        if coordinator.selection != .resourceSlots, !coordinator.canReturnToResourceSlots {
            readingState.clearFocusReturn()
        }
    }

    func actionLabel(_ id: String) -> String {
        "Open workflow run " + id
    }

    func didAppear() {
        appearances += 1
        trace?.mark("resource-mounted", details: ["appearance": String(appearances)])
        readingState.setSelected(coordinator.selection == .resourceSlots)
    }

    func didDisappear() {
        disappearances += 1
        trace?.ownerDidUnmount()
        trace?.mark("resource-unmounted", details: ["disappearance": String(disappearances)])
    }

    func didTapRefresh() {}
    func didToggleResource(_ id: String) {
        readingState.cancelRestorationForUser()
        if !expandedResourceIDs.insert(id).inserted { expandedResourceIDs.remove(id) }
    }

    func didToggleBlockers(_ id: String) {
        if !expandedBlockerIDs.insert(id).inserted { expandedBlockerIDs.remove(id) }
    }

    func didOpenOwner(_ rowID: String) {
        guard rowIDs.contains(rowID) else { return }
        trace?.mark("owner-route", details: ["rowID": rowID])
        readingState.prepareDeparture(ownerRowID: rowID)
        openedRows.append(rowID)
        coordinator.openResourceSlotOwner(.workflowRun(runID: rowID, activationID: "synthetic-activation"))
    }
}

struct ResourceSlotsInteractionContainer: View {
    let model: ResourceSlotsInteractionModel

    var body: some View {
        Group {
            if model.coordinator.selection == .resourceSlots {
                ResourceSlotsView(model)
            } else {
                VStack {
                    Text("Synthetic workflow owner destination")
                    if model.coordinator.canReturnToResourceSlots {
                        Button("Back to resource slots", action: model.returnToResourceSlots)
                    }
                }
            }
        }
        .frame(width: ResourceSlotsInteractionViewport.size.width, height: ResourceSlotsInteractionViewport.size.height)
        .environment(\.hfReduceMotionOverride, true)
        .onChange(of: model.coordinator.selection) { _, _ in model.selectionChanged() }
    }
}

enum ResourceSlotsInteractionViewport {
    static let size = CGSize(width: 1000, height: 620)
}

@MainActor
private func resourceInteractionRequireViewport(_ fixture: RedesignHost, expectedClipSize: CGSize? = nil,
                                                expectedWindowSize: CGSize? = nil) throws {
    let expected = ResourceSlotsInteractionViewport.size
    // The product layout surface is the fixture's fixed SwiftUI frame and the scroll clip
    // inside it — never the window's outer content rect, which is fixture chrome: SwiftUI
    // installs the resource view's own toolbar item into the bare fixture window at a
    // nondeterministic time and legitimately shrinks it (measured in the guarded run:
    // contentView 620 -> 588, exactly the toolbar height, while the scroll clip held
    // 983 x 620 across the whole trace). The outer rect is therefore not an oracle.
    try #require(abs(fixture.host.bounds.width - expected.width) < 0.5 && abs(fixture.host.bounds.height - expected.height) < 0.5,
                 Comment(rawValue: "Native fixture root viewport changed: expected=\(expected), actual=\(fixture.host.bounds.size)"))
    if let attached = resourceSlotsAttachedScroll(fixture) {
        try #require(abs(attached.clip.bounds.height - expected.height) < 0.5 && attached.clip.bounds.width > 0,
                     Comment(rawValue: "Native fixture scroll clip changed: expected height=\(expected.height), actual=\(attached.clip.bounds.size)"))
    }
    if let expectedWindowSize {
        let actual = fixture.window.frame.size
        print("RESOURCE_SLOTS_NATIVE_CHROME before=\(expectedWindowSize) after=\(actual) "
            + "contentLayoutRect=\(fixture.window.contentLayoutRect) toolbar=\(String(describing: fixture.window.toolbar.map(ObjectIdentifier.init)))")
    }
    if let expectedClipSize {
        let attached = try #require(resourceSlotsAttachedScroll(fixture))
        let actual = attached.clip.bounds.size
        try #require(abs(actual.width - expectedClipSize.width) < 0.5 && abs(actual.height - expectedClipSize.height) < 0.5,
                     Comment(rawValue: "Native resource viewport changed across unchanged content: before=\(expectedClipSize), after=\(actual)"))
    }
}

@MainActor
func resourceInteractionForeground(_ fixture: RedesignHost) async throws {
    NSApp.setActivationPolicy(.regular)
    fixture.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    await fixture.settle { fixture.window.isKeyWindow && NSApp.isActive }
    try #require(fixture.window.isKeyWindow && NSApp.isActive, "Native interactions require an unlocked foreground host")
}

@MainActor
func resourceInteractionScroll(_ fixture: RedesignHost) -> NSScrollView? {
    resourceSlotsAttachedScroll(fixture)?.scroll
}

@MainActor
func resourceInteractionVisibleOwner(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                     scroll: NSScrollView, candidates: [String]? = nil) -> (String, NSObject)? {
    let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
    for id in candidates ?? model.rowIDs {
        guard let element = fixture.element(model.actionLabel(id)), let frame = fixture.frame(element),
              frame.width > 0, frame.height > 0, viewport.insetBy(dx: 0, dy: 24).contains(frame) else { continue }
        return (id, element)
    }
    return nil
}

@MainActor
func resourceInteractionRelativeY(_ object: NSObject, fixture: RedesignHost, scroll: NSScrollView) -> CGFloat? {
    guard let frame = fixture.frame(object) else { return nil }
    return frame.minY - scroll.contentView.convert(scroll.contentView.bounds, to: nil).minY
}

@MainActor
func resourceInteractionRequireActiveHost(_ fixture: RedesignHost, _ model: ResourceSlotsInteractionModel) throws {
    try #require(fixture.window.isKeyWindow && NSApp.isActive,
                 Comment(rawValue: "Native keyboard environment lost key/active status: " + resourceInteractionDiagnostic(fixture, model)))
}

@MainActor
func resourceInteractionQualifyKeyboardHost(_ fixture: RedesignHost, _ model: ResourceSlotsInteractionModel) async throws {
    try resourceInteractionRequireActiveHost(fixture, model)
    let target = ResourceSlotsKeyboardProbe()
    let button = NSButton(title: "Native keyboard prerequisite", target: target, action: #selector(ResourceSlotsKeyboardProbe.activate))
    button.frame = CGRect(x: 12, y: 12, width: 220, height: 30)
    fixture.host.addSubview(button)
    model.trace?.calibrate(button)
    defer { button.removeFromSuperview(); _ = fixture.window.makeFirstResponder(nil) }
    print("RESOURCE_SLOTS_NATIVE stage=keyboard-prerequisite " + resourceInteractionDiagnostic(fixture, model))
    try #require(fixture.window.makeFirstResponder(button),
                 Comment(rawValue: "Host cannot focus a native button: " + resourceInteractionDiagnostic(fixture, model)))
    resourceInteractionSpace(fixture.window)
    await fixture.settle { target.activations == 1 }
    try #require(target.activations == 1,
                 Comment(rawValue: "Host cannot activate a focused native button with Space: " + resourceInteractionDiagnostic(fixture, model)))
}

@MainActor
private final class ResourceSlotsKeyboardProbe: NSObject {
    var activations = 0
    @objc func activate() {
        activations += 1
    }
}

@MainActor
private func resourceInteractionAXDiagnostic(_ fixture: RedesignHost) -> String {
    fixture.elements(in: fixture.host)
        .prefix(100)
        .map { element in
            let role = fixture.string(element, "accessibilityRole") ?? "nil"
            let label = fixture.string(element, "accessibilityLabel") ?? fixture.string(element, "accessibilityTitle") ?? "nil"
            let expanded = resourceSlotsLegacyAttributeValue(element, NSAccessibility.Attribute(rawValue: "AXExpanded"))
            return "role=\(role),label=\(label),expanded=\(String(describing: expanded))"
        }
        .joined(separator: "; ")
}

@MainActor
func resourceInteractionFocusedLabel(_ fixture: RedesignHost) -> String? {
    let focused = resourceSlotsNativeFocusedElement(fixture)
    guard let focused else { return nil }
    return fixture.string(focused, "accessibilityLabel") ?? fixture.string(focused, "accessibilityTitle")
}

@MainActor
private func resourceInteractionHeaderButtons(_ fixture: RedesignHost) -> [NSObject] {
    resourceSlotsNativeHeaders(fixture, groupID: "native-resource")
}

@MainActor
private func resourceInteractionRequireHeader(_ fixture: RedesignHost, value: String) throws -> NSObject {
    let controls = resourceInteractionHeaderButtons(fixture)
    try #require(controls.count == 1, Comment(rawValue: "Expected one identified native resource header; subtree="
            + resourceInteractionAXDiagnostic(fixture)))
    let control = try #require(controls.first)
    let label = fixture.string(control, "accessibilityLabel") ?? fixture.string(control, "accessibilityTitle") ?? ""
    #expect(label.contains("Native resource") && label.contains("Synthetic observed holdings"))
    try resourceSlotsRequireNativeHeader(control, fixture: fixture, expanded: value == "Expanded")
    return control
}

@MainActor
private func resourceInteractionFocusedIdentifier(_ fixture: RedesignHost) -> String? {
    let object = resourceSlotsNativeFocusedElement(fixture)
    return object.flatMap { fixture.string($0, "accessibilityIdentifier") }
}

@MainActor
private func resourceInteractionVerifyHeaderHitArea(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                                    trace: ResourceSlotsNativeTrace) async throws {
    let expanded = try resourceInteractionRequireHeader(fixture, value: "Expanded")
    let initialState = try #require(resourceSlotsNativeHeaderState(expanded))
    let frame = try #require(fixture.frame(expanded))
    try #require(frame.width > fixture.host.bounds.width * 0.75 && frame.height > 20,
                 "The native action must span the full visual header rather than an isolated title/chevron")
    try resourceInteractionRequireActiveHost(fixture, model)
    resourceInteractionClick(CGPoint(x: frame.minX + 8, y: frame.maxY - 8), window: fixture.window)
    await fixture.settle { !model.expandedResourceIDs.contains("native-resource") }
    try #require(!model.expandedResourceIDs.contains("native-resource"), "The leading header area must toggle the real binding")
    trace.surveyDisclosure(expandedModel: false)
    let collapsed = try resourceInteractionRequireHeader(fixture, value: "Collapsed")
    let collapsedState = try #require(resourceSlotsNativeHeaderState(collapsed))
    #expect(collapsedState.attribute == initialState.attribute && collapsedState.kind == initialState.kind)
    let collapsedFrame = try #require(fixture.frame(collapsed))
    try resourceInteractionRequireActiveHost(fixture, model)
    resourceInteractionClick(CGPoint(x: collapsedFrame.maxX - 8, y: collapsedFrame.minY + 8), window: fixture.window)
    await fixture.settle { model.expandedResourceIDs.contains("native-resource") }
    try #require(model.expandedResourceIDs.contains("native-resource"), "The trailing header area must toggle the real binding")
    _ = try resourceInteractionRequireHeader(fixture, value: "Expanded")
    trace.mark("header-full-hit-area-verified")
}

@MainActor
private func resourceInteractionClick(_ point: CGPoint, window: NSWindow) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }
}

@MainActor
func resourceInteractionSpace(_ window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                           isARepeat: false, keyCode: 49) else { return }
        window.sendEvent(event)
    }
}

@MainActor
func resourceInteractionDiagnostic(_ fixture: RedesignHost, _ model: ResourceSlotsInteractionModel) -> String {
    let scroll = resourceInteractionScroll(fixture)
    let keyboardMode = UserDefaults.standard.object(forKey: "AppleKeyboardUIMode").map { String(describing: $0) } ?? "unset"
    let responder = fixture.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    return "keyboardMode=\(keyboardMode), responder=\(responder), key=\(fixture.window.isKeyWindow), active=\(NSApp.isActive), "
        + "nativeOffset=\(String(describing: scroll?.contentView.bounds.minY)), "
        + "documentHeight=\(String(describing: scroll?.documentView?.bounds.height)), retained=\(model.readingState.retainedOffset), "
        + "restoring=\(model.readingState.isRestoring), focusedAX=\(resourceInteractionFocusedLabel(fixture) ?? "nil"), "
        + "appearances=\(model.appearances), disappearances=\(model.disappearances), opened=\(model.openedRows)"
}
