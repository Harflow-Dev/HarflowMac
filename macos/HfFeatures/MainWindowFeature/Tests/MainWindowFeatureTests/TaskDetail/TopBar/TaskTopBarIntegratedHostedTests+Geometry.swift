//
//  TaskTopBarIntegratedHostedTests+Geometry.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature

// MARK: - Settled geometry

/// What the real window, the shell's width band and the rendered principal looked like at one moment.
struct TopBarGeometry {
    let requested: CGFloat
    let contentWidth: CGFloat
    let rootWidth: CGFloat
    /// The band the shell derives from the actual content width.
    let band: TopBarWidthBand
    let principalWidth: CGFloat?
    let titleWidth: CGFloat?
    let metaDrawn: Bool
    let predictedTitle: CGFloat
    let predictedMeta: Bool
    let predictedCap: CGFloat
    /// The window has the requested content width and the shell's band for it.
    let windowSettled: Bool
    /// Whether the principal is laid out for this width. For a title that always fills its cap (a 120 character one) that is
    /// the band's cap, so a principal at an older band's cap is not yet laid out for this width. A title that fits keeps its
    /// ideal width, below the cap, so only a positive width within the cap is required there.
    let principalReady: Bool

    /// Consecutive passes with these conditions true and an unchanged title and principal width, as achieved when the settle
    /// returned. Zero for a sample taken outside `settleGeometry`.
    var stablePasses = 0

    /// Passes the settle must observe in a row before geometry counts as settled.
    static let requiredStablePasses = 10

    /// The conditions hold now and held, unchanged, for the required number of consecutive passes. A timed-out wait cannot
    /// satisfy this with an instantaneous reading.
    var isSettled: Bool { windowSettled && principalReady && stablePasses >= Self.requiredStablePasses }

    /// A width with one decimal, for the diagnostic lines.
    static func text(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }

    var summary: String {
        "stable passes \(stablePasses), requested \(requested), content \(contentWidth), root \(rootWidth), band \(band), "
            + "principal \(principalWidth.map(Self.text) ?? "none"), "
            + "cap \(predictedCap), title \(titleWidth.map(Self.text) ?? "none") (rule predicts \(predictedTitle)), "
            + "meta \(metaDrawn) (rule predicts \(predictedMeta))"
    }
}

extension TaskTopBarIntegratedHostedTests {

    func geometry(_ fixture: Fixture, requested width: CGFloat, prediction: TopBarIdealWidths.Prediction?, expectsCap: Bool) -> TopBarGeometry {
        let expectedBand = TopBarWidthBand(width: width)
        let principalWidth = fixture.principalItem.flatMap { fixture.screenFrame(of: $0) }?.width
        let cap = expectedBand.cap
        let ready: Bool = if let principalWidth {
            expectsCap ? abs(principalWidth - cap) <= 4 : principalWidth > 0 && principalWidth <= cap + 4
        } else {
            false
        }
        return TopBarGeometry(
            requested: width, contentWidth: fixture.contentWidth, rootWidth: fixture.rootWidth, band: fixture.band,
            principalWidth: principalWidth, titleWidth: titleWidth(fixture), metaDrawn: metaIsDrawn(fixture),
            predictedTitle: prediction?.solution.titleWidth ?? 0, predictedMeta: prediction?.expectsMeta ?? false, predictedCap: cap,
            windowSettled: abs(fixture.contentWidth - width) <= 1 && abs(fixture.rootWidth - width) <= 1 && fixture.band == expectedBand,
            principalReady: ready
        )
    }

    /// The solver's prediction for the published content at `width`'s band, from independently measured parts. Measured once
    /// per settle: the content and the band do not change while it waits.
    func prediction(_ fixture: Fixture, requested width: CGFloat) -> TopBarIdealWidths.Prediction? {
        fixture.content.map {
            TopBarIdealWidths.predict(content: $0, band: TopBarWidthBand(width: width), statusView: fixture.coordinator.buildConnectionStatusView())
        }
    }

    /// Sets the requested content width explicitly, then waits until the window and the hosting root really have it, the shell's
    /// band matches and the principal is laid out for that band (at its cap when `expectsCap`, which only a title longer than
    /// the cap guarantees), with an unchanged title and principal width for ten consecutive passes. Logs what it saw either
    /// way, so a timeout is diagnosable. Callers must take baselines and compare only after this returns settled geometry.
    func settleGeometry(_ fixture: Fixture, requested width: CGFloat, expectsCap: Bool, stage: String) async -> TopBarGeometry {
        fixture.window.setContentSize(NSSize(width: width, height: fixture.config.height))
        let predicted = prediction(fixture, requested: width)
        var stable = 0
        var previous: TopBarGeometry?
        await waitUntil(timeout: 10) {
            fixture.pump()
            let now = geometry(fixture, requested: width, prediction: predicted, expectsCap: expectsCap)
            if now.windowSettled, now.principalReady, let previous, previous.titleWidth == now.titleWidth, previous.principalWidth == now.principalWidth {
                stable += 1
            } else {
                stable = 0
            }
            previous = now
            return stable >= TopBarGeometry.requiredStablePasses
        }
        var final = geometry(fixture, requested: width, prediction: predicted, expectsCap: expectsCap)
        final.stablePasses = stable
        print("TOPBAR geometry \(stage) \(final.isSettled ? "settled" : "NOT SETTLED") after \(stable) stable passes: \(final.summary)")
        return final
    }

    // MARK: - Allocated title slot

    /// The title's drawn glyph frame, the badge beside it and the slot between them, all in screen coordinates.
    struct TitleSlot {
        let glyph: CGRect
        let badge: CGRect
        /// Title-leading to badge-leading, minus the layout's group gap: the width the layout allocated to the title.
        let width: CGFloat
    }

    /// A measured slot, or why it could not be measured. A failure is never replaced by the prediction, the principal's
    /// width or zero: callers must fail on it.
    enum TitleSlotMeasurement {
        case measured(TitleSlot)
        case failed(String)

        var slot: TitleSlot? {
            if case let .measured(slot) = self { slot } else { nil }
        }

        var failure: String? {
            if case let .failed(reason) = self { reason } else { nil }
        }
    }

    /// Measures the title's allocated slot from the rendered principal. The badge must be positively identified in the SAME
    /// principal host view as the title: a nonempty badge label, exactly one distinct element carrying it, visible, with a
    /// positive frame inside the principal's frame and the window, and after the title's leading edge. A title element that is
    /// not the full title text, or has no positive on-screen frame, fails as well.
    func measureTitleSlot(_ fixture: Fixture) -> TitleSlotMeasurement {
        guard let content = fixture.content else { return .failed("no published content") }
        guard let principal = fixture.principalItem, let host = principal.view, host.window === fixture.window else {
            return .failed("no principal host view in the window")
        }
        guard let principalFrame = fixture.screenFrame(of: principal), principalFrame.width > 0 else {
            return .failed("principal has no positive frame")
        }
        let elements = fixture.elements(in: host)
        let glyph: CGRect
        switch measureGlyph(fixture, content: content, in: elements) {
        case let .success(frame): glyph = frame
        case let .failure(reason): return .failed(reason.text)
        }
        let badge: CGRect
        switch measureBadge(fixture, content: content, principalFrame: principalFrame, in: elements) {
        case let .success(frame): badge = frame
        case let .failure(reason): return .failed(reason.text)
        }
        guard badge.minX > glyph.minX else { return .failed("the badge \(badge) does not follow the title \(glyph)") }
        return .measured(TitleSlot(glyph: glyph, badge: badge, width: badge.minX - glyph.minX - TopBarPrincipalLayout.spacing))
    }

    struct MeasurementFailure: Error {
        let text: String
    }

    /// The full title text, exactly, with a positive frame on screen.
    private func measureGlyph(_ fixture: Fixture, content: TaskTopBarContent, in elements: [NSObject]) -> Result<CGRect, MeasurementFailure> {
        guard let element = elements.first(where: { fixture.matches($0, content.title) }) else {
            return .failure(.init(text: "the principal host has no element carrying the full title text"))
        }
        let frame = fixture.screenFrame(ofElement: element)
        guard let frame, frame.width > 0, frame.height > 0, fixture.window.frame.insetBy(dx: -1, dy: -1).contains(frame) else {
            return .failure(.init(text: "the title glyph frame \(String(describing: frame)) is not positive and on screen"))
        }
        return .success(frame)
    }

    /// The one badge element of the principal host: nonempty label, not hidden, one distinct frame, positive and visible.
    private func measureBadge(_ fixture: Fixture, content: TaskTopBarContent, principalFrame: CGRect,
                              in elements: [NSObject]) -> Result<CGRect, MeasurementFailure> {
        let label = content.badge.label
        guard !label.isEmpty else { return .failure(.init(text: "the published badge has an empty label")) }
        let candidates = elements.filter { element in
            guard let text = fixture.label(element), text.hasPrefix(label) else { return false }
            return !fixture.matches(element, content.title) && !fixture.matches(element, content.metaText)
        }
        guard !candidates.isEmpty else { return .failure(.init(text: "no element in the principal host carries the badge label \(label)")) }
        if candidates.contains(where: { ($0 as? NSView)?.isHiddenOrHasHiddenAncestor == true }) {
            return .failure(.init(text: "a badge element is hidden"))
        }
        let frames = candidates.compactMap(fixture.screenFrame(ofElement:))
        guard frames.count == candidates.count, let badge = frames.first else {
            return .failure(.init(text: "a badge element reports no frame"))
        }
        guard frames.allSatisfy({ abs($0.minX - badge.minX) <= 1 && abs($0.width - badge.width) <= 1 }) else {
            return .failure(.init(text: "more than one distinct element carries the badge label: \(frames)"))
        }
        let visible = principalFrame.insetBy(dx: -1, dy: -1).contains(badge) && fixture.window.frame.insetBy(dx: -1, dy: -1).contains(badge)
        guard badge.width > 0, badge.height > 0, visible else {
            return .failure(.init(text: "the badge frame \(badge) is not positive and visible inside the principal \(principalFrame)"))
        }
        return .success(badge)
    }

    // MARK: - Slot versus glyph measurement

    /// Logs, for one matrix point, the screen frames of the principal's parts and the solver's exact inputs, so the title's
    /// accessibility frame (the drawn glyph run) can be compared with the slot the layout allocated to it. Measurement only:
    /// it asserts nothing and decides nothing. The slot is the distance from the title's leading edge to the badge's leading
    /// edge minus the layout's group gap; if it equals the prediction while the glyph frame is narrower, the layout is right
    /// and the title element reports its text, not its slot.
    func logSlotMeasurement(_ fixture: Fixture, prediction: TopBarIdealWidths.Prediction, stage: String) {
        guard let principal = fixture.principalItem, let view = principal.view else {
            print("TOPBAR slot [\(stage)] no principal view")
            return
        }
        let origin: CGFloat = fixture.screenFrame(of: principal)?.minX ?? 0
        func rel(_ frame: CGRect?) -> String {
            guard let frame else { return "none" }
            return "x \(TopBarGeometry.text(frame.minX - origin)) w \(TopBarGeometry.text(frame.width)) h \(TopBarGeometry.text(frame.height))"
        }
        let content = fixture.content
        let titleFrame = content.flatMap { fixture.element(labelled: $0.title, in: view) }.flatMap(fixture.screenFrame(ofElement:))
        let badgeLabel = content?.badge.label ?? ""
        let badgeElement = fixture.elements(in: view).first { fixture.label($0)?.hasPrefix(badgeLabel) == true }
        let badgeFrame = badgeElement.flatMap(fixture.screenFrame(ofElement:))
        let metaFrame = content.flatMap { fixture.element(labelled: $0.metaText, in: view) }.flatMap(fixture.screenFrame(ofElement:))
        var slot = "unknown"
        if let titleFrame, let badgeFrame {
            slot = TopBarGeometry.text(badgeFrame.minX - titleFrame.minX - TopBarPrincipalLayout.spacing)
        }
        let solution = prediction.solution
        let metaIdeal = prediction.metaIdeal.map(TopBarGeometry.text) ?? "none"
        let fixedWidths = prediction.fixed.map(TopBarGeometry.text)
        let solvedMeta = solution.metaWidth.map(TopBarGeometry.text) ?? "none"
        let solvedBadge = solution.badgeWidth.map(TopBarGeometry.text) ?? "ideal"
        let frames = "title \(rel(titleFrame)) | badge \(rel(badgeFrame)) | meta \(rel(metaFrame)) | allocated slot \(slot)"
        let inputs = "solver titleIdeal \(TopBarGeometry.text(prediction.titleIdeal)) metaIdeal \(metaIdeal) "
            + "fixed(badge, busy, status) \(fixedWidths) badgeMinimum \(TopBarGeometry.text(prediction.badgeMinimum)) "
            + "gap \(TopBarGeometry.text(TopBarPrincipalLayout.spacing))"
        let outputs = "title \(TopBarGeometry.text(solution.titleWidth)) meta \(solvedMeta) metaDropped \(solution.metaDropped) badge \(solvedBadge)"
        print("TOPBAR slot [\(stage)] band \(fixture.band) cap \(TopBarGeometry.text(prediction.cap)): \(frames)")
        print("TOPBAR slot [\(stage)] \(inputs) -> \(outputs)")
        for element in fixture.elements(in: view).prefix(40) {
            let text = [fixture.label(element), fixture.string(element, "accessibilityValue"), fixture.string(element, "accessibilityTitle")]
                .compactMap(\.self)
.filter { !$0.isEmpty }
            print("TOPBAR slot [\(stage)]   \(type(of: element)) \(text) \(rel(fixture.screenFrame(ofElement: element)))")
        }
    }
}
