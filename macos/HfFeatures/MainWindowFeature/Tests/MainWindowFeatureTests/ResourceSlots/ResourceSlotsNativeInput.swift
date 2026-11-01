import AppKit
import CoreGraphics
import Foundation
import Testing

@MainActor
struct ResourceSlotsAttachedScroll {
    let scroll: NSScrollView
    let clip: NSClipView
    let document: NSView
    let window: NSWindow

    var offset: CGFloat { clip.bounds.minY }
    var maximumOffset: CGFloat { max(-scroll.contentInsets.top, document.bounds.height + scroll.contentInsets.bottom - clip.bounds.height) }
    var halfClip: CGFloat { floor(clip.bounds.height / 2) }
    var identity: String { "\(ObjectIdentifier(scroll))/\(ObjectIdentifier(clip))/\(ObjectIdentifier(document))" }
    var details: [String: String] {
        ["scroll": String(describing: ObjectIdentifier(scroll)), "clip": String(describing: ObjectIdentifier(clip)),
         "document": String(describing: ObjectIdentifier(document)), "ownWindow": String(scroll.window === window),
         "clipOwnWindow": String(clip.window === window), "documentOwnWindow": String(document.window === window),
         "scrollSuperview": scroll.superview.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
         "clipSuperview": clip.superview.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
         "documentSuperview": document.superview.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
         "offset": String(describing: offset), "clipBounds": String(describing: clip.bounds),
         "documentBounds": String(describing: document.bounds)]
    }
}

// One resolver for setup, calibration, tracing and viewport assertions, including short content.
@MainActor
func resourceSlotsAttachedScroll(_ fixture: RedesignHost) -> ResourceSlotsAttachedScroll? {
    for scroll in fixture.descendants.compactMap({ $0 as? NSScrollView }) {
        let clip = scroll.contentView
        guard let document = scroll.documentView, scroll.window === fixture.window, scroll.superview != nil,
              clip.window === fixture.window, clip.superview != nil, clip.isDescendant(of: scroll),
              document.window === fixture.window, document.superview != nil, document.isDescendant(of: clip),
              clip.bounds.width > 0, clip.bounds.height > 0, document.bounds.width > 0, document.bounds.height > 0,
              clip.bounds.minY.isFinite, document.bounds.height.isFinite else { continue }
        return .init(scroll: scroll, clip: clip, document: document, window: fixture.window)
    }
    return nil
}

@MainActor
final class ResourceSlotsNativeInput {
    private let fixture: RedesignHost
    private let trace: ResourceSlotsNativeTrace
    private let retainedOffset: @MainActor () -> CGFloat
    private var previousIdentity: String?
    private var totalEvents = 0

    init(fixture: RedesignHost, trace: ResourceSlotsNativeTrace, retainedOffset: @escaping @MainActor () -> CGFloat) {
        self.fixture = fixture
        self.trace = trace
        self.retainedOffset = retainedOffset
    }

    func requireSynchronizedLayout() async throws -> ResourceSlotsAttachedScroll {
        var prior: String?
        var stable = 0
        await fixture.settle {
            guard let current = self.resolve(stage: "initial-layout"), abs(current.offset - self.retainedOffset()) < 1 else {
                stable = 0
                return false
            }
            let key = current.identity + String(describing: current.clip.bounds) + String(describing: current.document.bounds)
            stable = key == prior ? stable + 1 : 1
            prior = key
            return stable >= 2
        }
        let current = try #require(resolve(stage: "initial-layout-qualified"))
        try #require(stable >= 2 && abs(current.offset - retainedOffset()) < 1,
                     "Initial attached native layout and retained point must agree before any setup wheel event")
        return current
    }

    func seekDeepOwner(_ visible: @MainActor (ResourceSlotsAttachedScroll) -> Bool) async throws -> ResourceSlotsAttachedScroll {
        var current = try await requireSynchronizedLayout()
        var events = 0
        var cap = setupCap(current)
        while events <= cap {
            current = try #require(resolve(stage: "setup-measure"))
            cap = max(cap, setupCap(current))
            if current.offset > 1800, abs(current.offset - retainedOffset()) < 1,
               current.maximumOffset - current.offset >= 48, visible(current) {
                trace.mark("native-setup-qualified", details: current.details.merging(
                    ["setupEvents": String(events), "derivedCap": String(cap)]) { _, new in new })
                return current
            }
            guard events < cap else { break }
            try #require(current.halfClip >= 1, "Bounded native setup requires positive clip height")
            events += 1
            current = try await wheel(current.halfClip, stage: "setup-\(events)-of-\(cap)")
        }
        Issue.record("Native setup exhausted its observed-height-derived wheel cap: \(events)/\(cap)")
        throw ResourceSlotsNativeInputFailure.setupExhausted
    }

    func calibrate(ownerLabel: String) async throws -> ResourceSlotsAttachedScroll {
        let original = try #require(resolve(stage: "calibration-original"))
        let originalOffset = original.offset
        let before = try ownerPoint(ownerLabel, attached: original)
        try #require(original.maximumOffset - originalOffset >= 48, "Calibration requires room for16pixels plus32pixel margin")
        trace.mark("coordinate-known-delta-before", details: original.details, owner: fixture.element(ownerLabel))
        let afterScroll = try await wheel(16, stage: "calibration-down")
        let moved = afterScroll.offset - originalOffset
        let after = try ownerPoint(ownerLabel, attached: afterScroll)
        try #require(moved > 0 && moved <= original.halfClip, "Calibration requires bounded measured positive native movement")
        #expect(abs((after.viewportTopY - before.viewportTopY) + moved) < 1)
        #expect(abs(after.documentTopY - before.documentTopY) < 1,
                "Qualified owner content origin must remain fixed across the measured native calibration delta")
        trace.mark("coordinate-known-delta-after", details: ["measuredDelta": String(describing: moved)], owner: fixture.element(ownerLabel))
        let restored = try await restore(originalOffset)
        let point = try ownerPoint(ownerLabel, attached: restored)
        try #require(abs(point.viewportTopY - before.viewportTopY) < 1)
        return restored
    }

    private func restore(_ original: CGFloat) async throws -> ResourceSlotsAttachedScroll {
        for event in 0 ..< 8 {
            let current = try #require(resolve(stage: "calibration-restore-measure"))
            let remaining = original - current.offset
            if abs(remaining) < 1, abs(current.offset - retainedOffset()) < 1 { return current }
            let amount = min(current.halfClip, abs(remaining)) * (remaining < 0 ? -1 : 1)
            _ = try await wheel(amount, stage: "calibration-restore-\(event + 1)-of-8")
        }
        let current = try #require(resolve(stage: "calibration-restore-final"))
        try #require(abs(current.offset - original) < 1 && abs(current.offset - retainedOffset()) < 1,
                     "Calibration must restore the pre-calibration measured point; nearby re-baselining is not allowed")
        return current
    }

    /// One wheel delivery. Everything is captured before the event is sent, because the
    /// attached-scroll values read live clip bounds.
    private struct WheelDelivery {
        let event: NSEvent
        let scroll: NSScrollView
        var details: [String: String]
        let pixels: Int32
        let start: CGFloat
        let desired: CGFloat
        let stage: String
    }

    private func wheel(_ desired: CGFloat, stage: String) async throws -> ResourceSlotsAttachedScroll {
        let before = try #require(resolve(stage: stage + "-before"))
        try #require(abs(desired) >= 1 && abs(desired) <= before.halfClip)
        let pixels = Int32(abs(desired).rounded()) * (desired < 0 ? -1 : 1)
        let wheelEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -pixels, wheel2: 0, wheel3: 0))
        wheelEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let event = try #require(NSEvent(cgEvent: wheelEvent))
        try #require(event.type == .scrollWheel)
        try #require(event.scrollingDeltaY * desired < 0, "Native wheel direction must match the requested path; no sign fallback is allowed")
        let start = before.offset
        let identity = before.identity
        let delivery = WheelDelivery(event: event, scroll: before.scroll, details: before.details,
                                     pixels: pixels, start: start, desired: desired, stage: stage)
        defer {
            trace.mark("native-wheel-after", details: (resourceSlotsAttachedScroll(fixture)?.details ?? [:]).merging(
                ["stage": stage, "capturedBeforeOffset": String(describing: start),
                 "capturedAfterAttachment": String(describing: before.details)]) { _, new in new })
        }
        if let settled = try await deliver(delivery, number: 1) {
            return settled
        }
        // Measured (diag2, 4-group setup-16 at offset 4650): the platform can swallow a single
        // synthetic continuous wheel event while a lazy row materializes — the tracking phase
        // fires, but the native offset never moves. A re-delivery is only legal when nothing
        // else moved: the same attachment identity, the offset still within 0.5 pt of the
        // captured start, and the retained point still equal to the measured native offset.
        // Every other outcome is a desync and fails instead of retrying blind.
        let current = try #require(resolve(stage: stage + "-re-delivery-check"))
        try #require(current.identity == identity && abs(current.offset - start) <= 0.5
                         && abs(current.offset - retainedOffset()) < 1,
                     "Native wheel must move and settle before continuing; the attachment, offset or retained point changed, so no re-delivery is allowed")
        trace.mark("native-wheel-swallowed", details: current.details.merging(
            ["stage": stage, "requestedPixels": String(pixels)]) { _, new in new })
        guard let settled = try await deliver(delivery, number: 2) else {
            Issue.record("Native wheel must move in the requested direction and synchronize to retained state before continuing (the offset never moved)")
            throw ResourceSlotsNativeInputFailure.wheelNotApplied
        }
        return settled
    }

    private func deliver(_ delivery: WheelDelivery, number: Int) async throws -> ResourceSlotsAttachedScroll? {
        totalEvents += 1
        var details = delivery.details
        details["stage"] = delivery.stage
        details["totalEvents"] = String(totalEvents)
        details["delivery"] = String(number)
        details["requestedPixels"] = String(delivery.pixels)
        details["scrollingDeltaY"] = String(describing: delivery.event.scrollingDeltaY)
        details["precise"] = String(delivery.event.hasPreciseScrollingDeltas)
        details["phase"] = String(describing: delivery.event.phase)
        details["momentumPhase"] = String(describing: delivery.event.momentumPhase)
        trace.mark("native-wheel-before", details: details)
        delivery.scroll.scrollWheel(with: delivery.event)
        return try await settleWheel(start: delivery.start, desired: delivery.desired, stage: delivery.stage)
    }

    private func settleWheel(start: CGFloat, desired: CGFloat, stage: String) async throws -> ResourceSlotsAttachedScroll? {
        var prior: String?
        var stable = 0
        await fixture.settle {
            guard let current = self.resolve(stage: stage + "-settle"), abs(current.offset - self.retainedOffset()) < 1,
                  (current.offset - start) * desired > 0 else { stable = 0; return false }
            let key = current.identity + String(describing: current.clip.bounds) + String(describing: current.document.bounds)
            stable = key == prior ? stable + 1 : 1
            prior = key
            return stable >= 2
        }
        guard let current = resolve(stage: stage + "-after"), stable >= 2,
              (current.offset - start) * desired > 0, abs(current.offset - retainedOffset()) < 1 else { return nil }
        return current
    }

    private func ownerPoint(_ label: String, attached: ResourceSlotsAttachedScroll) throws -> ResourceSlotsNativeCoordinateProbe {
        let owner = try #require(fixture.element(label))
        return try #require(resourceSlotsNativeCoordinateProbe(owner, fixture: fixture, scroll: attached.scroll))
    }

    private func resolve(stage: String) -> ResourceSlotsAttachedScroll? {
        let current = resourceSlotsAttachedScroll(fixture)
        let identity = current?.identity ?? "no-attached-scroll"
        if identity != previousIdentity {
            trace.mark("native-scroll-identity", details: (current?.details ?? [:]).merging(
                ["stage": stage, "previous": previousIdentity ?? "none", "current": identity]) { _, new in new })
            previousIdentity = identity
        }
        return current
    }

    private func setupCap(_ current: ResourceSlotsAttachedScroll) -> Int {
        let step = max(1, current.halfClip)
        return Int(min(120, ceil(max(0, current.document.bounds.height - current.clip.bounds.height) / step) + 8))
    }
}

private enum ResourceSlotsNativeInputFailure: Error { case setupExhausted, wheelNotApplied }
