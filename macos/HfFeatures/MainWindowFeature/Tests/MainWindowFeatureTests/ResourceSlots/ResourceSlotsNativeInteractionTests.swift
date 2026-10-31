import AppKit
import HfCommon
import HfCommonTestMock
import HfUI
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

// These checks require the opt-in native runner and an unlocked foreground window server.
extension ActivityFeedApprovalHostedTests {
    @Test func givenDeepResourceOwner_whenOpeningAndReturning_thenNativeOffsetAndKeyboardFocusAreRestored() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 120)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: CGSize(width: 1000, height: 620), appearance: .light)
        let previousPolicy = NSApp.activationPolicy()
        defer { fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        await fixture.settle { resourceInteractionScroll(fixture) != nil && model.appearances == 1 }
        let scroll = try #require(resourceInteractionScroll(fixture))
        // Exercise native scrolling, independently of the reading-state ScrollPosition.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2500))
        scroll.reflectScrolledClipView(scroll.contentView)
        await fixture.settle {
            scroll.contentView.bounds.minY > 1800
                && abs(model.readingState.retainedOffset - scroll.contentView.bounds.minY) < 1
                && resourceInteractionVisibleOwner(fixture, model: model, scroll: scroll) != nil
        }
        try #require(scroll.contentView.bounds.minY > 1800, Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        let (rowID, owner) = try #require(resourceInteractionVisibleOwner(fixture, model: model, scroll: scroll))
        let originalOffset = scroll.contentView.bounds.minY
        let originalDocumentHeight = try #require(scroll.documentView).bounds.height
        let ownerLabel = model.actionLabel(rowID)

        // when: the real coordinator route removes the production view, as owner navigation does.
        try #require(fixture.press(owner), "The qualified owner AX element must implement Press")
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.disappearances == 1 }
        try #require(coordinator.selection == .workflowRun(rowID))
        try #require(coordinator.canReturnToResourceSlots)
        try #require(model.disappearances == 1)
        try #require(resourceInteractionScroll(fixture) == nil, "Resource content must actually unmount")
        await fixture.settle { fixture.element("Back to resource slots") != nil }
        let back = try #require(fixture.element("Back to resource slots"))
        try #require(fixture.press(back))

        // then: compare actual native geometry after reconstruction, never just the cached field.
        await fixture.settle {
            guard let returned = resourceInteractionScroll(fixture), let document = returned.documentView else { return false }
            let maximum = max(0, document.bounds.height - returned.contentView.bounds.height)
            let expected = min(originalOffset, maximum)
            return model.appearances == 2 && !model.readingState.isRestoring
                && abs(returned.contentView.bounds.minY - expected) < 2
                && resourceInteractionFocusedLabel(fixture) == ownerLabel
        }
        let returned = try #require(resourceInteractionScroll(fixture))
        let document = try #require(returned.documentView)
        let maximum = max(0, document.bounds.height - returned.contentView.bounds.height)
        let expected = min(originalOffset, maximum)
        #expect(model.appearances == 2 && model.disappearances == 1)
        #expect(!coordinator.canReturnToResourceSlots)
        #expect(coordinator.selection == .resourceSlots)
        #expect(expected > 1800, "Unchanged deep content must not silently clamp to the top")
        #expect(abs(returned.contentView.bounds.minY - expected) < 2,
                Comment(rawValue: "before=\(originalOffset), originalHeight=\(originalDocumentHeight), expected=\(expected), "
                    + resourceInteractionDiagnostic(fixture, model)))
        #expect(resourceInteractionFocusedLabel(fixture) == ownerLabel,
                Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        // A real key event must activate that restored owner, without another AX Press or focus setter.
        resourceInteractionSpace(fixture.window)
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.openedRows.count == 2 }
        #expect(model.openedRows == [rowID, rowID], Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        #expect(coordinator.selection == .workflowRun(rowID))
        // The coordinator's return marker is exact-owner scoped and clears on unrelated selection.
        coordinator.selection = .statistics
        #expect(!coordinator.canReturnToResourceSlots)
    }

    @Test func givenResourceDisclosure_whenAXThenKeyboardToggle_thenNativeExpansionTracksBothDirections() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: CGSize(width: 1000, height: 620), appearance: .light)
        let previousPolicy = NSApp.activationPolicy()
        defer { fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        await fixture.settle { resourceInteractionDisclosure(fixture) != nil }
        let disclosure = try #require(resourceInteractionDisclosure(fixture),
                                      "Production resource header must expose a native AXExpanded element")
        let expanded = NSAccessibility.Attribute(rawValue: "AXExpanded")
        try #require(disclosure.accessibilityAttributeValue(expanded) as? Bool == true)
        // when: invoke the public accessibility expansion operation.
        disclosure.accessibilitySetValue(false, forAttribute: expanded)
        await fixture.settle { model.expandedResourceIDs.isEmpty }
        #expect(model.expandedResourceIDs.isEmpty)
        let collapsed = try #require(resourceInteractionDisclosure(fixture))
        #expect(collapsed.accessibilityAttributeValue(expanded) as? Bool == false)
        // then: focus the semantic native disclosure, then use an actual keyboard event to expand.
        collapsed.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXFocused"))
        await fixture.settle {
            resourceInteractionFocusedLabel(fixture)?.contains("Native resource") == true
        }
        try #require(resourceInteractionFocusedLabel(fixture)?.contains("Native resource") == true,
                     Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        resourceInteractionSpace(fixture.window)
        await fixture.settle { model.expandedResourceIDs.contains("native-resource") }
        #expect(model.expandedResourceIDs.contains("native-resource"))
        let reopened = try #require(resourceInteractionDisclosure(fixture))
        #expect(reopened.accessibilityAttributeValue(expanded) as? Bool == true)
        await fixture.settle { fixture.element(model.actionLabel("native-owner-0")) != nil }
        #expect(fixture.element(model.actionLabel("native-owner-0")) != nil)
    }
}

@MainActor @Observable
private final class ResourceSlotsInteractionModel: ResourceSlotsViewModel {
    let coordinator: MainWindowCoordinator
    let presentation: ResourceSlotsPresentation
    let rowIDs: [String]
    let readingState = ResourceSlotsReadingState()
    var expandedResourceIDs: Set<String> = ["native-resource"]
    var expandedBlockerIDs: Set<String> = []
    var appearances = 0
    var disappearances = 0
    var openedRows: [String] = []

    init(coordinator: MainWindowCoordinator, rowCount: Int) {
        self.coordinator = coordinator
        self.rowIDs = (0 ..< rowCount).map { "native-owner-\($0)" }
        let holders = (0 ..< rowCount).map { "native-owner-\($0)" }.map { id in
            ResourceSlotsOwner(id: id, title: id, ownerID: id, status: "Holding capacity", since: nil,
                               detail: "Synthetic native interaction fixture", position: nil,
                               action: .init(label: "Open workflow run", ownerID: id), blockers: nil)
        }
        self.presentation = .init(state: .ready(summary: "1 resource", groups: [
            .init(id: "native-resource", title: "Native resource", capacitySummary: "Synthetic observed holdings",
                  holderHeading: "Holders", holders: holders, emptyHolderMessage: nil, waiterHeading: nil, waiters: [])
        ]), qualifiers: [])
    }

    func actionLabel(_ id: String) -> String { "Open workflow run " + id }
    func didAppear() { appearances += 1 }
    func didDisappear() { disappearances += 1 }
    func didTapRefresh() {}
    func didToggleResource(_ id: String) {
        if !expandedResourceIDs.insert(id).inserted { expandedResourceIDs.remove(id) }
    }

    func didToggleBlockers(_ id: String) {
        if !expandedBlockerIDs.insert(id).inserted { expandedBlockerIDs.remove(id) }
    }

    func didOpenOwner(_ rowID: String) {
        guard rowIDs.contains(rowID) else { return }
        openedRows.append(rowID)
        coordinator.openResourceSlotOwner(.workflowRun(runID: rowID, activationID: "synthetic-activation"))
    }
}

private struct ResourceSlotsInteractionContainer: View {
    let model: ResourceSlotsInteractionModel

    var body: some View {
        Group {
            if model.coordinator.selection == .resourceSlots {
                ResourceSlotsView(model)
            } else {
                VStack {
                    Text("Synthetic workflow owner destination")
                    if model.coordinator.canReturnToResourceSlots {
                        Button("Back to resource slots", action: model.coordinator.returnToResourceSlots)
                    }
                }
            }
        }
        .environment(\.hfReduceMotionOverride, true)
    }
}

@MainActor
private func resourceInteractionForeground(_ fixture: RedesignHost) async throws {
    NSApp.setActivationPolicy(.regular)
    fixture.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    await fixture.settle { fixture.window.isKeyWindow && NSApp.isActive }
    try #require(fixture.window.isKeyWindow && NSApp.isActive, "Native interactions require an unlocked foreground host")
}

@MainActor
private func resourceInteractionScroll(_ fixture: RedesignHost) -> NSScrollView? {
    fixture.descendants.compactMap { $0 as? NSScrollView }.first { scroll in
        scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height } == true
    }
}

@MainActor
private func resourceInteractionVisibleOwner(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                             scroll: NSScrollView) -> (String, NSObject)? {
    let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
    for id in model.rowIDs {
        guard let element = fixture.element(model.actionLabel(id)), let frame = fixture.frame(element),
              frame.width > 0, frame.height > 0, viewport.insetBy(dx: 0, dy: 24).contains(frame) else { continue }
        return (id, element)
    }
    return nil
}

@MainActor
private func resourceInteractionFocusedLabel(_ fixture: RedesignHost) -> String? {
    let focused = fixture.window.accessibilityAttributeValue(.focusedUIElement) as? NSObject
        ?? NSApp.accessibilityAttributeValue(.focusedUIElement) as? NSObject
    guard let focused else { return nil }
    return fixture.string(focused, "accessibilityLabel") ?? fixture.string(focused, "accessibilityTitle")
}

@MainActor
private func resourceInteractionDisclosure(_ fixture: RedesignHost) -> NSObject? {
    let expanded = NSAccessibility.Attribute(rawValue: "AXExpanded")
    return fixture.descendants.flatMap { fixture.elements(in: $0) }.first {
        $0.accessibilityAttributeValue(expanded) is Bool
            && fixture.elements(in: $0).contains { fixture.matches($0, "Native resource") }
    }
}

@MainActor
private func resourceInteractionSpace(_ window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                          isARepeat: false, keyCode: 49) else { return }
        window.sendEvent(event)
    }
}

@MainActor
private func resourceInteractionDiagnostic(_ fixture: RedesignHost, _ model: ResourceSlotsInteractionModel) -> String {
    let scroll = resourceInteractionScroll(fixture)
    return "key=\(fixture.window.isKeyWindow), active=\(NSApp.isActive), nativeOffset=\(String(describing: scroll?.contentView.bounds.minY)), "
        + "documentHeight=\(String(describing: scroll?.documentView?.bounds.height)), retained=\(model.readingState.retainedOffset), "
        + "restoring=\(model.readingState.isRestoring), focusedAX=\(resourceInteractionFocusedLabel(fixture) ?? "nil"), "
        + "appearances=\(model.appearances), disappearances=\(model.disappearances), opened=\(model.openedRows)"
}

@MainActor @Suite
struct ResourceSlotsReadingStateTests {
    @Test func givenRetainedPosition_whenUnmountedLoadingOrZeroViewportGeometryArrives_thenReturnWaitsForReadyMeasuredOffset() {
        // given
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        state.update(.init(offset: 250, contentHeight: 2000, viewportHeight: 400), ready: true)
        state.focusedRowID = "owner"
        state.endAppearance()
        state.update(.init(offset: 0, contentHeight: 0, viewportHeight: 400), ready: true)
        // when
        state.beginAppearance()
        state.update(.init(offset: 0, contentHeight: 2000, viewportHeight: 400), ready: false)
        state.update(.init(offset: 0, contentHeight: 2000, viewportHeight: 0), ready: true)
        // then
        #expect(state.retainedOffset == 250)
        #expect(state.isRestoring)
        let visible = CGRect(x: 0, y: 20, width: 120, height: 30)
        #expect(!state.canRestoreFocus(rowID: "owner", frame: visible))
        state.update(.init(offset: 0, contentHeight: 2000, viewportHeight: 400), ready: true)
        #expect(state.isRestoring, "Issuing a scroll request does not establish native layout completion")
        state.update(.init(offset: 250, contentHeight: 2000, viewportHeight: 400), ready: true)
        #expect(!state.isRestoring)
        #expect(!state.canRestoreFocus(rowID: "owner", frame: .zero))
        #expect(!state.canRestoreFocus(rowID: "owner", frame: CGRect(x: 0, y: 500, width: 120, height: 30)))
        #expect(!state.canRestoreFocus(rowID: "different", frame: visible))
        #expect(state.canRestoreFocus(rowID: "owner", frame: visible))
        state.didRestoreFocus()
        #expect(!state.canRestoreFocus(rowID: "owner", frame: visible), "Measured focus restoration is consumed once per appearance")
    }

    @Test func givenDeepRetainedPosition_whenReturnedContentShrinks_thenRestorationRequiresTheMeasuredClampedOffset() {
        // given
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        state.update(.init(offset: 1600, contentHeight: 2400, viewportHeight: 400), ready: true)
        state.endAppearance()
        state.beginAppearance()
        // when
        state.update(.init(offset: 0, contentHeight: 650, viewportHeight: 400), ready: true)
        // then
        #expect(state.isRestoring)
        #expect(state.retainedOffset == 1600)
        state.update(.init(offset: 250, contentHeight: 650, viewportHeight: 400), ready: true)
        #expect(!state.isRestoring)
        #expect(state.retainedOffset == 250)
        state.endAppearance()
        state.beginAppearance()
        state.update(.init(offset: 0, contentHeight: 200, viewportHeight: 400), ready: true)
        #expect(!state.isRestoring)
        #expect(state.retainedOffset == 0, "Content shorter than its viewport clamps to zero")
    }

    @Test func givenLoadingAnnouncement_whenRemountingThenStartingANewLoad_thenOnlyTheNewTransitionAnnouncesAgain() {
        // given
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        #expect(state.takeLoadingAnnouncement(isLoading: true))
        #expect(!state.takeLoadingAnnouncement(isLoading: true))
        // when
        state.endAppearance()
        state.beginAppearance()
        // then
        #expect(!state.takeLoadingAnnouncement(isLoading: true))
        #expect(!state.takeLoadingAnnouncement(isLoading: false))
        #expect(state.takeLoadingAnnouncement(isLoading: true))
        #expect(!state.takeLoadingAnnouncement(isLoading: true))
    }
}
