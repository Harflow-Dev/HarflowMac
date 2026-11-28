import AppKit
import HfCommon
import HfCommonTestMock
@testable import MainWindowFeature
import Testing

/// F-RS-FKA-RETURN qualification: with Full Keyboard Access on, does keyboard focus return to
/// the owner control after owner activation, the owner's detail and Back, with no responder
/// reset between activation and restoration?
///
/// P1 and P2 run in the shipping shell (`MainWindowNavigationView` with a real `NSToolbar`);
/// C1 is a control in the old in-content container, whose Back shares the owner's hosting view.
/// The finding closes as not reproduced only when P1 and P2 both pass; C1 is recorded, never
/// used for disposition. The setting is never changed: without Full Keyboard Access each
/// variant records a skip and returns. Opt-in through `HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION`.
///
/// Evidence limits: the outside-input guard is an `NSEvent` local monitor for the window. Events
/// the test sends with `window.sendEvent` never reach it, the queued mouse release is tagged and
/// ignored, and events consumed inside nested tracking loops are invisible to it. A responder
/// transition is the last observed transition, not proof of cause; naming a mechanism needs
/// branch-level product instrumentation.
extension ActivityFeedApprovalHostedTests {
    @Test func givenFullKeyboardAccess_whenKeyboardOpensOwnerAndPressesShellBack_thenOwnerFocusReturnsInTheShippingShell() async {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        guard resourceSlotsShellHasFullKeyboardAccess("P1") else { return }
        await resourceSlotsShellRunInShell("P1", gesture: .keyboard)
    }

    @Test func givenFullKeyboardAccess_whenKeyboardOpensOwnerAndPointerPressesShellBack_thenOwnerFocusReturnsInTheShippingShell() async {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        guard resourceSlotsShellHasFullKeyboardAccess("P2") else { return }
        await resourceSlotsShellRunInShell("P2", gesture: .pointer)
    }

    @Test func givenFullKeyboardAccess_whenKeyboardOpensOwnerAndPressesContainerBack_thenControlRunIsRecordedOnly() async {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        guard resourceSlotsShellHasFullKeyboardAccess("C1") else { return }
        await resourceSlotsShellRunInContainer("C1")
    }
}

@MainActor
private func resourceSlotsShellHasFullKeyboardAccess(_ variant: String) -> Bool {
    guard NSApp.isFullKeyboardAccessEnabled else {
        print("RESOURCE_SLOTS_SHELL variant=\(variant) skipped: Full Keyboard Access is off; the setting is never changed")
        return false
    }
    return true
}

// MARK: - Shipping shell (P1, P2)

@MainActor
private func resourceSlotsShellRunInShell(_ name: String, gesture: ResourceSlotsBackGesture) async {
    let fixture = ResourceSlotsShellFixture()
    let model = fixture.model
    let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "shell-return-" + name.lowercased())
    let evidence = ResourceSlotsShellEvidence(fixture: fixture, state: model.readingState, trace: trace, variant: name)
    model.evidence = evidence
    var completed = false
    defer { trace.finish(testBodyCompleted: completed); fixture.close() }
    NSApp.setActivationPolicy(.regular)
    fixture.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    _ = await resourceSlotsShellWait(fixture, timeout: 3) {
        fixture.window.isKeyWindow && NSApp.isActive && M04ToolbarEvidence.isPopulated(fixture.window)
            && fixture.element("resource-slots-owner-" + model.rowIDs[0]) != nil
    }
    let rowID = model.rowIDs[0]
    let rig = ResourceSlotsReturnRig(
        fixture: fixture, state: model.readingState, trace: trace, rowID: rowID,
        detailMarker: ResourceSlotsShellModel.detailMarker(rowID), requiresToolbar: true,
        openedRows: { model.openedRows },
        isOnResourceSlots: { fixture.coordinator.selection == .resourceSlots },
        backAvailable: { fixture.coordinator.canReturnToResourceSlots },
        returnCallbacks: { model.returnCallbacks },
        backLocation: {
            let items = fixture.backItems()
            return ResourceSlotsBackLocation(itemCount: items.count, rawCount: items.reduce(0) { $0 + $1.buttons.count },
                                             frame: items.first?.buttons.first.flatMap { fixture.frame($0) },
                                             container: items.first?.item.view)
        },
        extraFocusable: { fixture.toolbarButtonCount() })
    let verdict = await resourceSlotsShellRun(name, gesture: gesture, rig: rig, evidence: evidence)
    resourceSlotsShellReport(name, verdict, evidence: evidence, recordsIssue: true)
    completed = true
}

// MARK: - Old container (C1)

@MainActor
private func resourceSlotsShellRunInContainer(_ name: String) async {
    let coordinator = MainWindowCoordinator(parent: MockCoordinator())
    coordinator.selection = .resourceSlots
    let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
    let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                               size: ResourceSlotsInteractionViewport.size, appearance: .light)
    fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
    let previousPolicy = NSApp.activationPolicy()
    let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "shell-return-" + name.lowercased())
    model.trace = trace
    let evidence = ResourceSlotsShellEvidence(fixture: fixture, state: model.readingState, trace: trace, variant: name)
    var completed = false
    defer { trace.finish(testBodyCompleted: completed); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
    do { try await resourceInteractionForeground(fixture) } catch {
        print("RESOURCE_SLOTS_SHELL variant=\(name) verdict=Unexecuted: host is not foreground (\(error))")
        return
    }
    let rowID = model.rowIDs[0]
    let rig = ResourceSlotsReturnRig(
        fixture: fixture, state: model.readingState, trace: trace, rowID: rowID,
        detailMarker: "Synthetic workflow owner destination", requiresToolbar: false,
        openedRows: { model.openedRows },
        isOnResourceSlots: { coordinator.selection == .resourceSlots },
        backAvailable: { coordinator.canReturnToResourceSlots },
        returnCallbacks: { trace.productionEventCount("focus-authorized") },
        backLocation: {
            let buttons = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
                fixture.string($0, "accessibilityRole") == "AXButton"
                    && [fixture.string($0, "accessibilityLabel"), fixture.string($0, "accessibilityTitle")]
                    .contains(ResourceSlotsShellFixture.backTitle)
            }
            return ResourceSlotsBackLocation(itemCount: buttons.isEmpty ? 0 : 1, rawCount: buttons.count,
                                             frame: buttons.first.flatMap { fixture.frame($0) }, container: nil)
        },
        extraFocusable: { 0 })
    let verdict = await resourceSlotsShellRun(name, gesture: .keyboard, rig: rig, evidence: evidence)
    // The control outcome is recorded for the masking comparison and never fails the suite.
    resourceSlotsShellReport(name, verdict, evidence: evidence, recordsIssue: false)
    completed = true
}
