import AppKit
import HfCommon
import HfCommonTestMock
@testable import MainWindowFeature
import SwiftUI
import Testing

/// Native owner-focus qualification for the resource slots screen (Revisions 1-3 of the
/// #45 plan). These checks require the opt-in native runner and an unlocked foreground
/// window server.
extension ActivityFeedApprovalHostedTests {
    @Test func givenRepeatedOwnerRoutes_whenReturningThroughBackTwice_thenEachCycleRestoresNativeOwnerFocusOnce() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: ResourceSlotsInteractionViewport.size, appearance: .light)
        fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
        let previousPolicy = NSApp.activationPolicy()
        let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "owner-return-repeated-back")
        model.trace = trace
        var testBodyCompleted = false
        defer { trace.finish(testBodyCompleted: testBodyCompleted); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        try await resourceInteractionQualifyKeyboardHost(fixture, model)
        let rowID = model.rowIDs[0]
        let ownerLabel = model.actionLabel(rowID)
        // when: the first owner route departs the production view.
        let owner = try #require(fixture.element(ownerLabel))
        try #require(fixture.press(owner))
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.disappearances == 1 }
        for cycle in 1 ... 2 {
            await fixture.settle { fixture.element("Back to resource slots") != nil }
            let back = try #require(fixture.element("Back to resource slots"))
            try resourceInteractionRequireActiveHost(fixture, model)
            trace.mark("back-press", details: ["cycle": String(cycle)])
            try #require(fixture.press(back))
            // then: the returned owner control is the actual first responder, once per cycle.
            await fixture.settle {
                coordinator.selection == .resourceSlots && model.appearances == cycle + 1
                    && resourceInteractionFocusedLabel(fixture) == ownerLabel
            }
            try #require(resourceInteractionFocusedLabel(fixture) == ownerLabel,
                         Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
            let responder = try #require(fixture.window.firstResponder as? ResourceSlotsOwnerButton.Control,
                                         Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
            try #require(responder.accessibilityIdentifier() == "resource-slots-owner-" + rowID,
                         Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
            var settled = 0
            await fixture.settle { settled += 1; return settled > 20 }
            try #require(fixture.window.firstResponder === responder,
                         "A completed restoration must not be repeated within one Back cycle")
            // Exactly one token-verified completion per Back cycle, counted from diagnostics.
            try #require(trace.productionEventCount("focus-restored") == cycle,
                         "Each Back cycle must complete exactly one token-verified focus restoration")
            try #require(trace.productionEventCount("focus-request") == cycle,
                         "Each Back cycle must issue exactly one fresh focus request")
            try resourceInteractionRequireActiveHost(fixture, model)
            resourceInteractionSpace(fixture.window)
            await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.openedRows.count == cycle + 1 }
            try #require(model.openedRows.count == cycle + 1,
                         Comment(rawValue: "Exactly one activation per Back cycle: " + resourceInteractionDiagnostic(fixture, model)))
            trace.mark("cycle-space-reopened", details: ["cycle": String(cycle)])
        }
        #expect(model.openedRows == [rowID, rowID, rowID])
        // Trace evidence: three unmounts — the initial departure plus one Space-driven
        // departure per Back cycle — so the old == 2 expectation was wrong, not the flow.
        #expect(model.appearances == 3 && model.disappearances == 3)
        testBodyCompleted = true
    }

    @Test func givenReturningOwner_whenTheUserMovesFocusDuringRestoration_thenTheOwnerNeverStealsItBack() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: ResourceSlotsInteractionViewport.size, appearance: .light)
        fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
        let previousPolicy = NSApp.activationPolicy()
        let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "owner-return-user-focus")
        model.trace = trace
        var testBodyCompleted = false
        defer { trace.finish(testBodyCompleted: testBodyCompleted); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        try await resourceInteractionQualifyKeyboardHost(fixture, model)
        let rowID = model.rowIDs[0]
        let ownerLabel = model.actionLabel(rowID)
        let sentinel = NSButton(title: "Focus movement sentinel", target: nil, action: nil)
        sentinel.setAccessibilityIdentifier("focus-movement-sentinel")
        sentinel.frame = CGRect(x: 16, y: fixture.host.bounds.height - 60, width: 220, height: 30)
        fixture.host.addSubview(sentinel)
        let owner = try #require(fixture.element(ownerLabel))
        try #require(fixture.press(owner))
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.disappearances == 1 }
        await fixture.settle { fixture.element("Back to resource slots") != nil }
        let back = try #require(fixture.element("Back to resource slots"))
        try resourceInteractionRequireActiveHost(fixture, model)
        try #require(fixture.press(back))
        // The restoration must actually be in flight before the user moves focus: wait for the
        // returning owner control to be realized while holding its pending token, then move
        // focus inside the attempt's yield window.
        await fixture.settle {
            model.readingState.focusRestorationPending
                && resourceInteractionOwnerControl(fixture, rowID: rowID)?.hasPendingFocusRequest == true
        }
        try #require(model.readingState.focusRestorationPending, "The focus return must still be pending")
        let restoringControl = try #require(resourceInteractionOwnerControl(fixture, rowID: rowID),
                                            "The returning owner control must be realized")
        try #require(restoringControl.hasPendingFocusRequest, "The returning owner control must hold the pending focus token")
        try #require(fixture.window.makeFirstResponder(sentinel), "The sentinel must accept keyboard focus")
        // then: the owner control never reclaims focus the user moved away.
        await fixture.settle { model.appearances == 2 && fixture.element(ownerLabel) != nil }
        var settled = 0
        await fixture.settle { settled += 1; return settled > 40 }
        try #require(fixture.window.firstResponder === sentinel,
                     Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        #expect(!model.readingState.hasAuthorizedFocusReturn && !model.readingState.focusRestorationPending)
        #expect(resourceInteractionFocusedLabel(fixture) != ownerLabel)
        #expect(model.openedRows.count == 1, "Only the initial owner route ran; no Space was sent in this scenario")
        // The abandonment came from the user-moved-focus path, not from the frame budget.
        try #require(trace.productionEventCount("focus-request") >= 1, "A focus request must have been issued for the return")
        try #require(trace.productionEventCount("focus-user-moved") >= 1,
                     "The pending return must be cleared through the user-moved-focus path")
        #expect(trace.productionEventCount("focus-budget-exhausted") == 0,
                "The user-movement verdict must not be the frame budget giving up")
        testBodyCompleted = true
    }

    @Test func givenConsumedOwnerFocusRestoration_whenAnOrdinaryRefreshRebuildsTheRow_thenKeyboardFocusIsNotReclaimed() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: ResourceSlotsInteractionViewport.size, appearance: .light)
        fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
        let previousPolicy = NSApp.activationPolicy()
        let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "owner-return-refresh")
        model.trace = trace
        var testBodyCompleted = false
        defer { trace.finish(testBodyCompleted: testBodyCompleted); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        try await resourceInteractionQualifyKeyboardHost(fixture, model)
        let rowID = model.rowIDs[0]
        let ownerLabel = model.actionLabel(rowID)
        let sentinel = NSButton(title: "Refresh sentinel", target: nil, action: nil)
        sentinel.setAccessibilityIdentifier("refresh-sentinel")
        sentinel.frame = CGRect(x: 16, y: fixture.host.bounds.height - 60, width: 220, height: 30)
        fixture.host.addSubview(sentinel)
        let owner = try #require(fixture.element(ownerLabel))
        try #require(fixture.press(owner))
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.disappearances == 1 }
        await fixture.settle { fixture.element("Back to resource slots") != nil }
        let back = try #require(fixture.element("Back to resource slots"))
        try #require(fixture.press(back))
        await fixture.settle {
            coordinator.selection == .resourceSlots && model.appearances == 2
                && resourceInteractionFocusedLabel(fixture) == ownerLabel
        }
        try #require(resourceInteractionFocusedLabel(fixture) == ownerLabel,
                     Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        #expect(!model.readingState.focusRestorationPending, "The successful restoration already consumed its token")
        let controlBefore = try #require(resourceInteractionOwnerControl(fixture, rowID: rowID),
                                          "The focused owner control must exist before the refresh")
        // when: the user moves focus away and an ordinary refresh replaces the presentation
        // (a genuinely different value, so the content re-renders rather than de-duplicating).
        try #require(fixture.window.makeFirstResponder(sentinel))
        model.presentation = resourceInteractionRefreshedPresentation(from: model.presentation)
        await fixture.settle { fixture.element("Presentation replaced by the refresh") != nil }
        // then: the refreshed row's control was updated or replaced (it carries the replaced
        // presentation's action text), and the consumed restoration never refocuses it.
        let refreshedLabel = "Open refreshed run " + rowID
        try #require(fixture.element(refreshedLabel) != nil,
                     "The replaced presentation must re-render its owner rows")
        let controlAfter = try #require(resourceInteractionOwnerControl(fixture, rowID: rowID),
                                        "The presentation replacement must update or replace the owner control")
        // Evidence for updated-vs-replaced: the same instance was reconfigured, or a new
        // instance carried the row identity across the presentation replacement.
        trace.mark("refresh-control-outcome", details: ["updated": String(controlAfter === controlBefore),
                                                       "replaced": String(controlAfter !== controlBefore)])
        try #require(controlAfter.title == "Open refreshed run",
                     "The refreshed control must carry the replaced presentation's action text")
        try #require(fixture.window.firstResponder === sentinel,
                     Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        #expect(!model.readingState.hasAuthorizedFocusReturn && !model.readingState.focusRestorationPending)
        #expect(model.openedRows.count == 1)
        testBodyCompleted = true
    }

    @Test func givenSiblingTableHoldsFirstResponder_whenBackReturns_thenOwnerFocusIsStillRestored() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .resourceSlots
        let model = ResourceSlotsInteractionModel(coordinator: coordinator, rowCount: 4)
        let fixture = RedesignHost(ResourceSlotsInteractionContainer(model: model),
                                   size: ResourceSlotsInteractionViewport.size, appearance: .light)
        fixture.window.contentMinSize = ResourceSlotsInteractionViewport.size
        let previousPolicy = NSApp.activationPolicy()
        let trace = ResourceSlotsNativeTrace(state: model.readingState, fixture: fixture, scenario: "owner-return-sibling-table")
        model.trace = trace
        var testBodyCompleted = false
        defer { trace.finish(testBodyCompleted: testBodyCompleted); fixture.close(); NSApp.setActivationPolicy(previousPolicy) }
        try await resourceInteractionForeground(fixture)
        try await resourceInteractionQualifyKeyboardHost(fixture, model)
        let rowID = model.rowIDs[0]
        let ownerLabel = model.actionLabel(rowID)
        // A persistent sibling table holds keyboard focus before Back; it is the responder
        // authorizeFocusReturn captures at Back, so it must stay neutral during restoration.
        // NSHostingView does not support foreign subviews, so the table lives in a window-level
        // AppKit container beside the hosting view, with a frame, a column and one row so it
        // is a genuine first-responder-capable peer of the SwiftUI content.
        let container = NSView(frame: CGRect(origin: .zero, size: ResourceSlotsInteractionViewport.size))
        let host = fixture.host
        fixture.window.contentView = container
        container.addSubview(host)
        let table = NSTableView(frame: CGRect(x: 16, y: 16, width: 220, height: 64))
        table.setAccessibilityIdentifier("persistent-sibling-table")
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sibling-column")))
        let tableContent = SiblingTableContent()
        table.dataSource = tableContent
        container.addSubview(table)
        // Replacing the content view can resign the key window; the restoration attempt and
        // the active-host invariants both require it, so re-establish and verify it here.
        fixture.window.makeKeyAndOrderFront(nil)
        try resourceInteractionRequireActiveHost(fixture, model)
        try #require(fixture.window.makeFirstResponder(table), "The sibling table must accept keyboard focus")
        try #require(fixture.window.firstResponder === table, "The sibling table must hold keyboard focus before Back")
        // The container swap unmounted the content and SwiftUI remounts it asynchronously.
        // The owner route must wait for that fresh mount: the earlier press raced the remount,
        // ran prepareDeparture against a deselected reading state (guard selected) and left
        // focusedRowID nil, so no focus return was ever authorized (trace: focus-authorized
        // with focusedRow=nil, no focus-request, the table still first responder after Back).
        await fixture.settle {
            model.appearances == 2 && model.disappearances == 1 && fixture.element(ownerLabel) != nil
        }
        try #require(fixture.window.firstResponder === table, "The sibling table must keep focus across the remount")
        let owner = try #require(fixture.element(ownerLabel))
        try #require(fixture.press(owner))
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.disappearances == 2 }
        try #require(fixture.window.firstResponder === table, "The sibling table must keep focus across the departure")
        await fixture.settle { fixture.element("Back to resource slots") != nil }
        let back = try #require(fixture.element("Back to resource slots"))
        try resourceInteractionRequireActiveHost(fixture, model)
        try #require(fixture.press(back))
        // then: the owner control is still restored over the authorized sibling responder.
        await fixture.settle {
            coordinator.selection == .resourceSlots && model.appearances == 3
                && resourceInteractionFocusedLabel(fixture) == ownerLabel
        }
        let responder = try #require(fixture.window.firstResponder as? ResourceSlotsOwnerButton.Control,
                                     Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        try #require(responder.accessibilityIdentifier() == "resource-slots-owner-" + rowID,
                     Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
        try resourceInteractionRequireActiveHost(fixture, model)
        resourceInteractionSpace(fixture.window)
        await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.openedRows.count == 2 }
        #expect(model.openedRows == [rowID, rowID])
        testBodyCompleted = true
    }

    @Test func givenNativeOwnerButton_whenPressedDisabledFocusedAcrossAppearances_thenNativePixelsMatchTheTintedStyle() async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        // given: the real representable plus a hosted MonitorButtonStyle(.tinted) reference in
        // the same window, so the pressed capsule is compared against the real style it must
        // reproduce under the same appearance, never against approximated palette arithmetic.
        let probe = ResourceSlotsOwnerPixelProbe()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: probe.content())
        window.makeKeyAndOrderFront(nil)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); NSApp.setActivationPolicy(previousPolicy) }
        await fixturelessSettle {
            window.isKeyWindow && NSApp.isActive && probe.enabledControl(window) != nil
                && probe.disabledControl(window) != nil && probe.referenceFrame(window) != nil
        }
        try #require(window.isKeyWindow && NSApp.isActive)
        let enabled = try #require(probe.enabledControl(window), "The enabled owner control must be realized")
        let disabled = try #require(probe.disabledControl(window), "The disabled owner control must be realized")
        let referenceFrame = try #require(probe.referenceFrame(window), "The hosted tinted reference must be realized")
        let fillPoint = CGPoint(x: 6, y: enabled.bounds.midY)

        // The tinted capsule fill matches the palette in light, and a live appearance flip
        // re-resolves it in dark (Rev 3: redraw on viewDidChangeEffectiveAppearance). Every
        // window-server sample is stability-gated: the live flip cross-fades, and a single
        // capture can read the mid-transition blend (the dark fill once sampled the roughly
        // five percent light tail), so a capture is only used after two consecutive captures
        // agree byte for byte.
        let lightFill = try resourceInteractionPixel(enabled, at: fillPoint, window: window)
        try resourceInteractionExpectColor(lightFill, red: 0xE6, green: 0xEA, blue: 0xF8, context: "light fill")
        window.appearance = NSAppearance(named: .darkAqua)
        await fixturelessSettlePump(10)
        // The live flip must re-resolve the capsule in dark (Rev 3: redraw on
        // viewDidChangeEffectiveAppearance). The check is on screen and relative: the native
        // capsule is compared against the hosted tinted reference in the same flipped
        // window, through the same stability-gated capture (see the helper's documentation
        // for the full reasoning and the stale-redraw exclusion).
        try resourceInteractionExpectFlippedFillMatchesTheReference(enabled, referenceFrame: referenceFrame,
                                                                    lightFill: lightFill, window: window)
        window.appearance = NSAppearance(named: .aqua)
        await fixturelessSettlePump(10)

        // The disabled control keeps its fill and dims only the foreground (title band scan).
        let disabledFill = try resourceInteractionPixel(disabled, at: fillPoint, window: window)
        try resourceInteractionExpectColor(disabledFill, red: 0xE6, green: 0xEA, blue: 0xF8,
                                           context: "disabled fill matches the enabled fill")
        try resourceInteractionExpectDimmedTitle(enabled: enabled, disabled: disabled, window: window)

        // A focused control draws its capsule-shaped exterior focus ring around the bounds.
        let ringPoint = CGPoint(x: enabled.bounds.midX, y: enabled.bounds.minY - 3)
        let ringBefore = try resourceInteractionPixel(enabled, at: ringPoint, window: window)
        probe.focusToken = UUID()
        await fixturelessSettle { window.firstResponder === enabled }
        try #require(window.firstResponder === enabled, "The owner control must accept keyboard focus while a token is pending")
        await fixturelessSettlePump(5)
        let ringAfter = try resourceInteractionPixel(enabled, at: ringPoint, window: window)
        try #require(resourceInteractionColorDistance(ringBefore, ringAfter) > 0.08,
                     "The focused owner control must draw its exterior focus ring")

        // Pressed pixels against the hosted tinted reference, in both appearances: the native
        // capsule is sampled mid-tracking and the reference mid-press, each from the same
        // window-server capture, and each must prove it observed the pressed state before the
        // fill and title-ink comparisons run (see the comparison helper's own documentation).
        try await resourceInteractionExpectPressedPixelsMatchTheTintedReference(enabled, referenceFrame: referenceFrame,
                                                                                window: window, appearance: "light")

        // The same comparison holds in dark appearance, after the live flip settles.
        window.appearance = NSAppearance(named: .darkAqua)
        await fixturelessSettlePump(10)
        try await resourceInteractionExpectPressedPixelsMatchTheTintedReference(enabled, referenceFrame: referenceFrame,
                                                                                window: window, appearance: "dark")
    }
}

@MainActor
private func resourceInteractionOwnerControl(_ fixture: RedesignHost, rowID: String) -> ResourceSlotsOwnerButton.Control? {
    fixture.descendants
.compactMap { $0 as? ResourceSlotsOwnerButton.Control }
        .first { $0.accessibilityIdentifier() == "resource-slots-owner-" + rowID }
}

/// A genuinely different presentation for the refresh scenario: the same rows, a new summary,
/// a qualifier and a replaced owner action label, so the content must re-render its rows.
@MainActor
private func resourceInteractionRefreshedPresentation(from presentation: ResourceSlotsPresentation) -> ResourceSlotsPresentation {
    var groups: [ResourceSlotsGroup] = []
    if case let .ready(_, existing) = presentation.state { groups = existing }
    let refreshed = groups.map { group in
        ResourceSlotsGroup(id: group.id, title: group.title, capacitySummary: group.capacitySummary,
                           holderHeading: group.holderHeading,
                           holders: group.holders.map { holder in
                               ResourceSlotsOwner(id: holder.id, title: holder.title, ownerID: holder.ownerID,
                                                  status: holder.status, since: holder.since, detail: holder.detail,
                                                  position: holder.position,
                                                  action: .init(label: "Open refreshed run", ownerID: holder.ownerID),
                                                  blockers: holder.blockers)
                           },
                           emptyHolderMessage: group.emptyHolderMessage, waiterHeading: group.waiterHeading,
                           waiters: group.waiters)
    }
    return ResourceSlotsPresentation(
        state: .ready(summary: "Synthetic resource inventory (refreshed)", groups: refreshed),
        qualifiers: [ResourceSlotsQualifier(id: "refresh", text: "Presentation replaced by the refresh", isWarning: false)]
    )
}

/// One row of AppKit-owned content, so the sibling table is a genuine first responder.
@MainActor
private final class SiblingTableContent: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
}
