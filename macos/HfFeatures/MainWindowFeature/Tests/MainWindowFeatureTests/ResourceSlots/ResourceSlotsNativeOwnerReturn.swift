import AppKit
@testable import MainWindowFeature
import Testing

/// The owner-return flow of the native interaction test (the extension in
/// `ResourceSlotsNativeInteractionTests`): the departure baseline, the coordinator route and
/// the return oracles, plus the chrome-settling and viewport helpers they rely on.

@MainActor
struct ResourceSlotsDepartureSnapshot {
    let rowID: String
    let owner: NSObject
    let originalScroll: NSScrollView
    let originalHostSize: CGSize
    let originalClipSize: CGSize
    let originalWindowWidth: CGFloat
    let originalOffset: CGFloat
    let originalDocumentHeight: CGFloat
    let originalOwnerY: CGFloat
    let ownerLabel: String
    let groupCount: Int
    let neighbourhood: [String: CGFloat]
}

@MainActor
func resourceInteractionPrepareReading(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                       groupCount: Int, trace: ResourceSlotsNativeTrace) async throws -> ResourceSlotsDepartureSnapshot {
    let input = ResourceSlotsNativeInput(fixture: fixture, trace: trace, retainedOffset: { model.readingState.retainedOffset })
    // Remove the chrome race before any coordinate work: the bare fixture window receives the
    // resource view's SwiftUI toolbar item at a nondeterministic time, and installing it
    // shrinks the window's content rect — sometimes the host's fixed frame as well (measured
    // in the guarded runs: 620 -> 588, exactly the toolbar height). The settle is bounded and
    // returns only once the toolbar is installed and the host and clip sizes have stopped
    // changing, so the synchronized layout, the calibration and the departure baseline all
    // live in the final chrome regime and every later viewport oracle compares against the
    // captured sizes, never the constant 620.
    try await resourceInteractionSettleChrome(fixture)
    let initial = try await input.requireSynchronizedLayout()
    trace.calibrate()
    let originalHostSize = fixture.host.bounds.size
    try #require(abs(originalHostSize.width - ResourceSlotsInteractionViewport.size.width) < 0.5 && originalHostSize.height > 500,
                 Comment(rawValue: "Native fixture root viewport is not a usable layout surface after the chrome settled: \(originalHostSize)"))
    let targetRows = groupCount == 1 ? model.rowIDs : model.rowsByGroup[2]
    if groupCount > 1 {
        try #require(resourceInteractionVisibleOwner(fixture, model: model, scroll: initial.scroll, candidates: targetRows) == nil,
                     "The multi-group case must begin with its saved resource group offscreen")
    }
    let reached = try await input.seekDeepOwner { current in
        resourceInteractionVisibleOwner(fixture, model: model, scroll: current.scroll, candidates: targetRows) != nil
    }
    let (rowID, _) = try #require(resourceInteractionVisibleOwner(fixture, model: model, scroll: reached.scroll, candidates: targetRows))
    let ownerLabel = model.actionLabel(rowID)
    _ = try await input.calibrate(ownerLabel: ownerLabel)
    let current = try #require(resourceSlotsAttachedScroll(fixture))
    let scroll = current.scroll
    try #require(current.offset > 1800 && abs(model.readingState.retainedOffset - current.offset) < 1)
    let (_, owner) = try #require(resourceInteractionVisibleOwner(fixture, model: model, scroll: scroll, candidates: [rowID]))
    let originalOffset = scroll.contentView.bounds.minY
    let originalDocumentHeight = try #require(scroll.documentView).bounds.height
    let originalOwnerY = try #require(resourceInteractionRelativeY(owner, fixture: fixture, scroll: scroll))
    let neighbourhood = resourceInteractionVisibleNeighbourhood(fixture, model: model, scroll: scroll)
    try #require(neighbourhood[rowID] != nil && neighbourhood.count >= 2,
                 "The departure baseline must record the owner plus at least one visible neighbour, saw: \(neighbourhood.keys.sorted())")
    trace.mark("activation", details: ["groupCount": String(groupCount),
                                       "originalOracleOwnerY": String(describing: originalOwnerY),
                                       "visibleNeighbourhood": String(neighbourhood.count)], owner: owner)
    try resourceInteractionRequireActiveHost(fixture, model)
    print("RESOURCE_SLOTS_NATIVE stage=activation groupCount=\(groupCount) owner=\(rowID) relativeY=\(originalOwnerY) "
        + resourceInteractionDiagnostic(fixture, model))

    return ResourceSlotsDepartureSnapshot(rowID: rowID, owner: owner, originalScroll: scroll,
                                          originalHostSize: originalHostSize,
                                          originalClipSize: scroll.contentView.bounds.size, originalWindowWidth: fixture.window.frame.width,
                                          originalOffset: originalOffset,
                                          originalDocumentHeight: originalDocumentHeight, originalOwnerY: originalOwnerY, ownerLabel: ownerLabel,
                                          groupCount: groupCount, neighbourhood: neighbourhood)
}

@MainActor
func resourceInteractionRouteAndBack(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                     departure: ResourceSlotsDepartureSnapshot, trace: ResourceSlotsNativeTrace) async throws {
    let coordinator = model.coordinator
    let rowID = departure.rowID
    let owner = departure.owner
    // when: the exact coordinator owner route removes the production view.
    try #require(fixture.press(owner), "The qualified owner AX element must implement Press")
    await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.disappearances == 1 }
    try #require(coordinator.selection == .workflowRun(rowID))
    try #require(coordinator.canReturnToResourceSlots)
    try #require(model.disappearances == 1)
    try #require(resourceInteractionScroll(fixture) == nil, "Resource content must actually unmount")
    // The unmount check asserts only what is deterministic while the content is gone: the
    // content is unmounted and the window's WIDTH is unchanged. No height is asserted — the
    // window's outer frame is not toolbar-invariant either: AppKit resizes the frame when the
    // toolbar and titlebar chrome changes, nondeterministically (measured in run 10: a
    // departure frame of 672 pt tall read 652 pt at unmount in the single-group case and
    // 620 pt in the four-group case, at widths that never moved). The host and the scroll
    // clip are compared against the departure snapshot once the content returns.
    try resourceInteractionRequireWindowWidth(fixture, expectedWidth: departure.originalWindowWidth)
    print("RESOURCE_SLOTS_NATIVE stage=disappearance " + resourceInteractionDiagnostic(fixture, model))
    await fixture.settle { fixture.element("Back to resource slots") != nil }
    let back = try #require(fixture.element("Back to resource slots"))
    try resourceInteractionRequireActiveHost(fixture, model)
    trace.mark("back-press")
    try #require(fixture.press(back))
}

@MainActor
func resourceInteractionVerifyReturn(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                     departure: ResourceSlotsDepartureSnapshot, trace: ResourceSlotsNativeTrace) async throws {
    let coordinator = model.coordinator
    let rowID = departure.rowID
    let originalOffset = departure.originalOffset
    let originalDocumentHeight = departure.originalDocumentHeight
    let originalOwnerY = departure.originalOwnerY
    let ownerLabel = departure.ownerLabel
    // The chrome settles again after the remount, before the return measurements.
    try await resourceInteractionSettleChrome(fixture)
    // then: unchanged content must preserve the original point and owner position, even if lazy extent estimates shrink.
    // The absolute offset is an oracle only for the single-group case; the settle therefore
    // waits on the owner's viewport-relative point, the completed restoration and the focus
    // for both cases (the relative point proves the scroll landed at the anchor).
    let expectExactOffset = departure.groupCount == 1
    await fixture.settle {
        guard let returned = resourceInteractionScroll(fixture), let action = fixture.element(ownerLabel),
              let relativeY = resourceInteractionRelativeY(action, fixture: fixture, scroll: returned)
        else {
            trace.observePresentation()
            return false
        }
        trace.observePresentation(owner: action)
        return model.appearances == 2 && !model.readingState.isRestoring
            && (!expectExactOffset || abs(returned.contentView.bounds.minY - originalOffset) < 2)
            && abs(relativeY - originalOwnerY) < 2
            && resourceInteractionFocusedLabel(fixture) == ownerLabel
    }
    let returned = try #require(resourceInteractionScroll(fixture))
    try resourceInteractionRequireStableViewport(fixture, departure: departure)
    let returnedOwner = try #require(fixture.element(ownerLabel))
    let returnedOwnerY = try #require(resourceInteractionRelativeY(returnedOwner, fixture: fixture, scroll: returned))
    trace.mark("return-oracles", owner: returnedOwner)
    print("RESOURCE_SLOTS_NATIVE stage=return originalOffset=\(originalOffset) originalHeight=\(originalDocumentHeight) "
        + "originalOwnerY=\(originalOwnerY) returnedOwnerY=\(returnedOwnerY) " + resourceInteractionDiagnostic(fixture, model))
    #expect(model.appearances == 2 && model.disappearances == 1)
    #expect(!coordinator.canReturnToResourceSlots)
    #expect(coordinator.selection == .resourceSlots)
    if expectExactOffset {
        #expect(abs(returned.contentView.bounds.minY - originalOffset) < 2,
                Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
    } else {
        // Multi-group: the absolute offset is not an oracle here (see the neighbourhood
        // oracle's documentation for the measured evidence).
        try resourceInteractionExpectVisibleNeighbourhood(fixture, model: model, departure: departure, scroll: returned)
    }
    #expect(abs(returnedOwnerY - originalOwnerY) < 2, "Unchanged owner must retain its viewport-relative point")
    try resourceInteractionRequireActiveHost(fixture, model)
    trace.mark("before-owner-focus-assertion", owner: returnedOwner)
    try #require(resourceInteractionFocusedLabel(fixture) == ownerLabel,
                 Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
    // The real owner control is the window's actual first responder, not just the AX-focused element.
    let responder = try #require(fixture.window.firstResponder as? ResourceSlotsOwnerButton.Control,
                                 Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
    try #require(responder.accessibilityIdentifier() == "resource-slots-owner-" + rowID,
                 Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
    // Never reactivate after the owner action: host loss is a failed environment prerequisite.
    try resourceInteractionRequireActiveHost(fixture, model)
    resourceInteractionSpace(fixture.window)
    await fixture.settle { coordinator.selection == .workflowRun(rowID) && model.openedRows.count == 2 }
    #expect(model.openedRows == [rowID, rowID], Comment(rawValue: resourceInteractionDiagnostic(fixture, model)))
    #expect(coordinator.selection == .workflowRun(rowID))
}

/// The multi-group return oracle. The lazy estimate of the not-yet-realized content above the
/// anchor changes the document height between departure and return (measured, runs 8/9: the
/// owner returned to the identical viewport-relative point while the document went
/// 14888 -> 14483 and the absolute offset 7750 -> 7439), so the absolute offset is not an
/// oracle for multi-group. The oracle is the visible neighbourhood: every departure-visible
/// row that is still visible on return keeps its viewport-relative position within 2pt, and
/// at least the owner plus one neighbour must be compared.
@MainActor
private func resourceInteractionExpectVisibleNeighbourhood(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                                           departure: ResourceSlotsDepartureSnapshot,
                                                           scroll: NSScrollView) throws {
    let returnedNeighbourhood = resourceInteractionVisibleNeighbourhood(fixture, model: model, scroll: scroll)
    var compared = 0
    var mismatches: [String] = []
    for (id, originalY) in departure.neighbourhood {
        guard let returnedY = returnedNeighbourhood[id] else { continue }
        compared += 1
        if abs(returnedY - originalY) >= 2 {
            mismatches.append("\(id): \(originalY) -> \(returnedY)")
        }
    }
    let departureRows = departure.neighbourhood.keys.sorted()
    let returnedRows = returnedNeighbourhood.keys.sorted()
    try #require(compared >= 2,
                 Comment(rawValue: "The visible-neighbourhood oracle needs the owner plus a still-visible neighbour; "
                    + "departure=\(departureRows), returned=\(returnedRows)"))
    #expect(mismatches.isEmpty,
            Comment(rawValue: "Visible rows moved across the return: " + mismatches.joined(separator: "; ")))
}

/// Removes the fixture-chrome race before any viewport measurement. The bare fixture window
/// receives the resource view's SwiftUI toolbar item at a nondeterministic time, and
/// installing it shrinks the window's content rect — sometimes the host's fixed frame as
/// well (measured in the guarded runs: 620 -> 588, exactly the toolbar height). The settle
/// is bounded by `waitUntil`, which returns silently on timeout, so the stabilized verdict
/// is kept in `didStabilize` and required afterwards with the last sampled sizes: the
/// toolbar is installed, the scroll clip is attached with a positive size (a nil clip can
/// never count as stable), and the host and clip sizes are equal across two consecutive
/// layout passes.
@MainActor
private func resourceInteractionSettleChrome(_ fixture: RedesignHost) async throws {
    var previousHost: CGSize?
    var previousClip: CGSize?
    var didStabilize = false
    var lastHost = CGSize.zero
    var lastClip: CGSize?
    await fixture.settle {
        let host = fixture.host.bounds.size
        let clip = resourceSlotsAttachedScroll(fixture)?.clip.bounds.size
        didStabilize = fixture.window.toolbar != nil
            && clip.map { $0.width > 0 && $0.height > 0 } == true
            && host == previousHost && clip == previousClip
        previousHost = host
        previousClip = clip
        lastHost = host
        lastClip = clip
        return didStabilize
    }
    try #require(didStabilize,
                 Comment(rawValue: "The fixture chrome never settled before the baseline: host=\(lastHost), clip=\(String(describing: lastClip))"))
}

/// The only chrome measurement that is deterministic while the content is unmounted: the
/// window's outer width. No height is asserted — AppKit resizes the frame when the toolbar
/// and titlebar chrome changes, nondeterministically (measured in run 10: 672 pt tall at
/// departure, 652 pt at unmount in the single-group case, 620 pt in the four-group case,
/// at widths that never moved).
@MainActor
private func resourceInteractionRequireWindowWidth(_ fixture: RedesignHost, expectedWidth: CGFloat) throws {
    try #require(abs(fixture.window.frame.width - expectedWidth) < 0.5,
                 Comment(rawValue: "Native fixture window width changed: expected=\(expectedWidth), actual=\(fixture.window.frame.width)"))
}

/// The returned content's layout oracle: the host and the scroll clip are compared against
/// the sizes captured at departure, after the chrome settled — never the constant 620,
/// because the bare fixture window receives the resource view's SwiftUI toolbar item at a
/// nondeterministic time and installing it shrinks the layout surface (measured: 620 -> 588).
@MainActor
private func resourceInteractionRequireStableViewport(_ fixture: RedesignHost,
                                                      departure: ResourceSlotsDepartureSnapshot) throws {
    try #require(abs(fixture.host.bounds.width - departure.originalHostSize.width) < 0.5
                     && abs(fixture.host.bounds.height - departure.originalHostSize.height) < 0.5,
                 Comment(rawValue: "Native fixture root viewport changed across the return: "
                    + "before=\(departure.originalHostSize), after=\(fixture.host.bounds.size)"))
    let attached = try #require(resourceSlotsAttachedScroll(fixture))
    let actual = attached.clip.bounds.size
    try #require(abs(actual.width - departure.originalClipSize.width) < 0.5
                     && abs(actual.height - departure.originalClipSize.height) < 0.5,
                 Comment(rawValue: "Native resource viewport changed across unchanged content: before=\(departure.originalClipSize), after=\(actual)"))
    try resourceInteractionRequireWindowWidth(fixture, expectedWidth: departure.originalWindowWidth)
}

/// The visible neighbourhood at a moment in time: every owner row whose action element frame
/// sits inside the viewport (inset by 24pt so partially clipped rows are excluded), keyed by
/// row id with its viewport-relative Y. Only realized rows appear, which is exactly the
/// neighbourhood the reading anchor preserves.
@MainActor
private func resourceInteractionVisibleNeighbourhood(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                                     scroll: NSScrollView) -> [String: CGFloat] {
    let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
    var rows: [String: CGFloat] = [:]
    for id in model.rowIDs {
        guard let element = fixture.element(model.actionLabel(id)), let frame = fixture.frame(element),
              frame.width > 0, frame.height > 0, viewport.insetBy(dx: 0, dy: 24).contains(frame),
              let relativeY = resourceInteractionRelativeY(element, fixture: fixture, scroll: scroll)
        else { continue }
        rows[id] = relativeY
    }
    return rows
}
