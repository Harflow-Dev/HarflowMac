import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

/// Static look of the layer indicators against the SwiftUI drawings they replaced, in light and dark,
/// in a window with an explicit appearance; and the live appearance switch.
///
/// A running animation cannot be captured in process (Core Animation composites in the render
/// server), so each indicator is frozen: the arc's rotation and the layer opacity are set on the
/// model layers, and the layer tree is rendered with `CALayer.render(in:)`. A layer's own opacity is
/// not composited by that render, so the caret and dot are compared at full ink scaled analytically
/// by the opacity, against SwiftUI's `.opacity(x)`.
@MainActor @Suite(.serialized) struct LayerMotionLookHostedTests {
    /// Measured on this machine (see the `LAYER_MOTION_MEASURED` lines), with headroom.
    private enum Tolerance {
        /// Ink bounds and glyph size, in points (one pixel at 2x).
        static let geometry: CGFloat = 0.5
        /// Strongest ink colour of a fully covered pixel, in 8-bit levels.
        static let color: Double = 3
        /// The same at a translucent opacity, where the reference's 8-bit alpha quantises.
        static let translucentColor: Double = 6
        /// Caret glyph: worst single component difference, in levels. Measured ink bounds (alpha above 2%):
        /// `Text` x 4.5, width 3.5; candidate x 4.0, width 4.0. Both end at x 8.0, and top and bottom agree, so
        /// the candidate has one extra, faint, left-edge pixel column (a 2x pixel is 0.5 pt) and no layout
        /// offset: the bar's left edge falls inside that pixel, which `NSAttributedString.draw` antialiases at
        /// partial coverage and SwiftUI's glyph rendering does not. That column accounts for the 38 (light)
        /// and 71 (dark; heavier edge coverage) level worst-pixel difference and the +2.4% / +4.4% ink area.
        /// With a 50% alpha threshold the bounds coincide (checked in the size test), which is the evidence.
        static let caretMax: Double = 75
        /// Caret glyph: mean per-component difference across the raster, in levels (measured 0.29 light, 0.90 dark).
        static let caretMean: Double = 1.2
        /// Caret glyph: ink area relative difference (measured +2.4% light, +4.4% dark).
        static let caretArea: Double = 0.06
        /// Anti-aliased shapes: worst single component difference, in levels (measured 10).
        static let shapeMax: Double = 12
        /// Anti-aliased shapes: mean per-component difference, in levels (measured 0.13 at most).
        static let shapeMean: Double = 0.25
        /// Anti-aliased shapes: ink area relative difference (measured 0.6% at most).
        static let shapeArea: Double = 0.01
    }

    private typealias Color4 = (red: Double, green: Double, blue: Double, alpha: Double)
    private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    private static let pad: CGFloat = 4

    // MARK: Helpers

    private func name(_ appearance: NSAppearance.Name) -> String { appearance == .aqua ? "light" : "dark" }

    private func resolved(_ color: Color, _ appearance: NSAppearance.Name) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var result = (red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            if let value = NSColor(color).usingColorSpace(.sRGB) {
                result = (Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent), Double(value.alphaComponent))
            }
        }
        return result
    }

    private func levels(_ lhs: (red: Double, green: Double, blue: Double, alpha: Double),
                        _ rhs: (red: Double, green: Double, blue: Double, alpha: Double)) -> Double {
        max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue)) * 255
    }

    private func cgColor(_ color: CGColor?) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let color, let value = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent), Double(value.alphaComponent))
    }

    /// Renders a SwiftUI reference in the fixture's window (so it takes the window's appearance) and
    /// returns its raster and size once it has drawn something.
    private func reference(_ view: some View, in fixture: LayerMotionFixture) async -> (bitmap: LayerMotionBitmap, size: CGSize)? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: CGPoint(x: 0, y: 0), size: host.fittingSize)
        fixture.container.addSubview(host)
        defer { host.removeFromSuperview() }
        var bitmap: LayerMotionBitmap?
        await waitUntil {
            bitmap = LayerMotionRender.display(of: host)
            return bitmap?.inkBounds() != nil
        }
        guard let bitmap else { return nil }
        return (bitmap, host.bounds.size)
    }

    /// Renders `view` inside a non-flipped container of `size`, `pad` points in from the top left. A
    /// layer-backed view only pushes its frame and updated layer to Core Animation on a run-loop turn,
    /// so this renders again until something is drawn.
    private func candidate(_ view: NSView, size: CGSize, in fixture: LayerMotionFixture,
                           prepare: (() -> Void)? = nil) async -> LayerMotionBitmap? {
        let container = NSView(frame: CGRect(origin: CGPoint(x: 0, y: 0), size: size))
        container.wantsLayer = true
        fixture.container.addSubview(container)
        defer { container.removeFromSuperview() }
        view.frame.origin = CGPoint(x: Self.pad, y: size.height - Self.pad - view.frame.height)
        container.addSubview(view)
        var bitmap: LayerMotionBitmap?
        await waitUntil {
            view.layoutSubtreeIfNeeded()
            prepare?()
            bitmap = LayerMotionRender.layerTree(of: container)
            return bitmap?.inkBounds() != nil
        }
        return bitmap
    }

    private func report(_ label: String, _ reference: LayerMotionBitmap, _ candidate: LayerMotionBitmap) {
        let boundsReference = reference.inkBounds() ?? .zero
        let boundsCandidate = candidate.inkBounds() ?? .zero
        print("LAYER_MOTION_MEASURED \(label) max=\(reference.maxDifference(from: candidate)) mean=\(reference.meanDifference(from: candidate)) "
            + "area_ref=\(reference.inkArea) area_cand=\(candidate.inkArea) bounds_ref=\(boundsReference) bounds_cand=\(boundsCandidate)")
    }

    private func expectSameBounds(_ reference: LayerMotionBitmap, _ candidate: LayerMotionBitmap, _ label: String) {
        guard let lhs = reference.inkBounds(), let rhs = candidate.inkBounds() else {
            Issue.record("\(label): a raster is blank (reference \(reference.inkBounds() != nil), candidate \(candidate.inkBounds() != nil))")
            return
        }
        #expect(abs(lhs.minX - rhs.minX) <= Tolerance.geometry, "\(label) minX \(lhs) vs \(rhs)")
        #expect(abs(lhs.minY - rhs.minY) <= Tolerance.geometry, "\(label) minY \(lhs) vs \(rhs)")
        #expect(abs(lhs.width - rhs.width) <= Tolerance.geometry, "\(label) width \(lhs) vs \(rhs)")
        #expect(abs(lhs.height - rhs.height) <= Tolerance.geometry, "\(label) height \(lhs) vs \(rhs)")
    }

    private func expectStrokeMatch(_ reference: LayerMotionBitmap, _ candidate: LayerMotionBitmap, _ label: String) {
        report(label, reference, candidate)
        expectSameBounds(reference, candidate, label)
        #expect(reference.meanDifference(from: candidate) <= Tolerance.shapeMean, "\(label) mean difference")
        #expect(reference.maxDifference(from: candidate) <= Tolerance.shapeMax, "\(label) max difference")
        let area = reference.inkArea
        #expect(area > 0 && abs(candidate.inkArea - area) / area <= Tolerance.shapeArea, "\(label) ink area \(candidate.inkArea) vs \(area)")
    }

    /// The spec a feed wrapper really passes to its layer view.
    private func spec(of wrapper: some View, in fixture: LayerMotionFixture) async -> LayerSpinnerSpec? {
        let host = NSHostingView(rootView: AnyView(wrapper.environment(\.hfReduceMotionOverride, true)))
        host.frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        fixture.container.addSubview(host)
        defer { host.removeFromSuperview() }
        await waitUntil { !LayerMotionProbe.views(LayerSpinnerView.self, in: host).isEmpty }
        return LayerMotionProbe.views(LayerSpinnerView.self, in: host).first?.spec
    }

    // MARK: Caret

    @Test func givenCaret_whenSizedAndPlaced_thenItEqualsTheTextGlyphInTheSameFont() async throws {
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            let font = NSFont.monospacedSystemFont(ofSize: HfTextStyle.body.pointSize, weight: .regular)
            let view = LayerCaretView(font: font, color: Color.secondaryText)
            let text = Text("\u{258D}").font(.hf(.body, design: .monospaced)).foregroundStyle(Color.secondaryText)
            // when
            let host = NSHostingView(rootView: text)
            let textSize = host.fittingSize
            // then: size
            print("LAYER_MOTION_MEASURED caret_size_\(name(appearance)) text=\(textSize) caret=\(view.glyphSize)")
            #expect(abs(view.glyphSize.width - textSize.width) <= 0.01, "\(name(appearance)) width")
            #expect(abs(view.glyphSize.height - textSize.height) <= 0.01, "\(name(appearance)) height")
            // then: position of the ink inside the frame
            let padded = text.padding(Self.pad)
            let referenceRender = try #require(await reference(padded, in: fixture))
            let size = referenceRender.size
            let rendered = try #require(await candidate(view, size: size, in: fixture))
            report("caret_\(name(appearance))", referenceRender.bitmap, rendered)
            expectSameBounds(referenceRender.bitmap, rendered, "caret \(name(appearance))")
            // the solid part of the bar (alpha above 50%) coincides: the offset is only the faint edge column
            let solidReference = try #require(referenceRender.bitmap.inkBounds(threshold: 0.5))
            let solidCandidate = try #require(rendered.inkBounds(threshold: 0.5))
            print("LAYER_MOTION_MEASURED caret_solid_bounds_\(name(appearance)) reference=\(solidReference) candidate=\(solidCandidate)")
            #expect(abs(solidReference.minX - solidCandidate.minX) <= 0.01 && abs(solidReference.width - solidCandidate.width) <= 0.01,
                    "solid caret bounds \(solidReference) vs \(solidCandidate)")
            #expect(abs(solidReference.minY - solidCandidate.minY) <= 0.01 && abs(solidReference.height - solidCandidate.height) <= 0.01)
            #expect(referenceRender.bitmap.meanDifference(from: rendered) <= Tolerance.caretMean)
            #expect(abs(rendered.inkArea - referenceRender.bitmap.inkArea) / referenceRender.bitmap.inkArea <= Tolerance.caretArea)
        }
    }

    @Test func givenCaretAtFixedOpacities_whenRendered_thenInkMatchesTheOpacityModifier() async throws {
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            let font = NSFont.monospacedSystemFont(ofSize: HfTextStyle.body.pointSize, weight: .regular)
            let view = LayerCaretView(font: font, color: Color.secondaryText)
            let probe = try #require(await reference(
                Text("\u{258D}").font(.hf(.body, design: .monospaced)).foregroundStyle(Color.secondaryText).padding(Self.pad), in: fixture))
            let full = try #require(await candidate(view, size: probe.size, in: fixture))
            for opacity in [1.0, 0.6, 0.2] {
                // when
                let expected = try #require(await reference(
                    Text("\u{258D}")
.font(.hf(.body, design: .monospaced))
.foregroundStyle(Color.secondaryText)
.opacity(opacity)
                        .padding(Self.pad), in: fixture))
                let scaled = full.applyingOpacity(opacity)
                // then
                report("caret_ink_\(name(appearance))_\(opacity)", expected.bitmap, scaled)
                #expect(expected.bitmap.maxDifference(from: scaled) <= Tolerance.caretMax, "\(name(appearance)) opacity \(opacity)")
                #expect(expected.bitmap.meanDifference(from: scaled) <= Tolerance.caretMean, "\(name(appearance)) opacity \(opacity)")
                let reference = expected.bitmap.strongestInkColor()
                let drawn = scaled.strongestInkColor()
                if let reference, let drawn {
                    #expect(abs(reference.alpha - drawn.alpha) * 255 <= Tolerance.color, "alpha at \(opacity)")
                    #expect(levels((reference.red, reference.green, reference.blue, 1), (drawn.red, drawn.green, drawn.blue, 1)) <= Tolerance.color)
                } else {
                    Issue.record("blank caret raster at opacity \(opacity)")
                }
            }
        }
    }

    // MARK: Spinner

    private func spinnerReference(color: Color, ringOpacity: Double, stroke: CGFloat, size: CGFloat, turns: Double) -> some View {
        ZStack {
            Circle().stroke(color.opacity(ringOpacity), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(turns * 360))
        }
        .frame(width: size, height: size)
        .padding(Self.pad)
    }

    @Test func givenToolSpinner_whenFrozenAtRotations_thenItMatchesRunningSpinnersDrawing() async throws {
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            let size = HfRadius.Metrics.spacing12
            let spec = try #require(await spec(of: FeedRunningSpinner(size: size), in: fixture))
            #expect(spec.diameter == size && spec.margin == 0 && spec.lineWidth == HfRadius.Metrics.spinnerStroke)
            #expect(spec.arcFraction == 0.3 && spec.period == 1 && spec.ringOpacity == 0.2)
            for turns in [0.0, 0.25, 0.5, 0.8] {
                // when
                // At rest (turns == 0) the reference is HfUI's real `RunningSpinner` under Reduce Motion, which
                // holds the arc at 0. A rotated arc cannot be frozen in the real view (its angle comes from a
                // `TimelineView` clock), so the rotated frames compare against a copy of its body.
                let referenceView: AnyView = turns == 0
                    ? AnyView(RunningSpinner(size: size).environment(\.hfReduceMotionOverride, true).padding(Self.pad))
                    : AnyView(spinnerReference(color: Color.runningFG, ringOpacity: 0.2, stroke: HfRadius.Metrics.spinnerStroke,
                                               size: size, turns: turns))
                let expected = try #require(await reference(referenceView, in: fixture))
                let view = LayerSpinnerView(spec: spec)
                let rendered = try #require(await candidate(view, size: expected.size, in: fixture) {
                    LayerMotion.withoutActions { view.turningLayer.transform = CATransform3DMakeRotation(turns * 2 * .pi, 0, 0, 1) }
                })
                // then
                expectStrokeMatch(expected.bitmap, rendered, "spinner_\(name(appearance))_\(turns)")
                // the stroke is not clipped at the view's bounds: ink reaches past the frame by half a line width
                let ink = try #require(rendered.inkBounds())
                #expect(ink.minX < Self.pad && ink.minY < Self.pad, "stroke must extend past the \(size) pt frame, ink \(ink)")
            }
        }
    }

    @Test func givenSpinnerColours_whenAppliedUnderAnAppearance_thenRingAndArcUseTheResolvedPalette() async throws {
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            let spec = try #require(await spec(of: FeedRunningSpinner(), in: fixture))
            let view = LayerSpinnerView(spec: spec)
            // when
            fixture.container.addSubview(view)
            // then
            let arc = try #require(cgColor((view.turningLayer as? CAShapeLayer)?.strokeColor))
            let ring = try #require(cgColor((view.trackLayer as? CAShapeLayer)?.strokeColor))
            let expected = resolved(Color.runningFG, appearance)
            #expect(levels(arc, expected) <= Tolerance.color, "\(name(appearance)) arc")
            #expect(levels(ring, expected) <= Tolerance.color, "\(name(appearance)) ring")
            #expect(abs(arc.alpha - expected.alpha) * 255 <= Tolerance.color)
            #expect(abs(ring.alpha - expected.alpha * 0.2) * 255 <= Tolerance.color, "ring is the 20% track")
        }
    }

    // MARK: Working glyph

    @Test func givenWorkingGlyph_whenFrozenAtRotations_thenItMatchesItsPreviousDrawing() async throws {
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            let spec = try #require(await spec(of: TranscriptWorkingGlyph(), in: fixture))
            #expect(spec.diameter == TaskScreenStyle.Working.glyphSize && spec.margin == TaskScreenStyle.Working.glyphMargin)
            #expect(spec.lineWidth == TaskScreenStyle.Working.glyphRingWidth && spec.arcFraction == 0.25)
            #expect(spec.period == TaskScreenStyle.Working.spinDuration && spec.ringOpacity == 1)
            for turns in [0.0, 0.25, 0.6] {
                // when: the former body, minus its clock
                let former = ZStack {
                    Circle().stroke(TaskScreenStyle.Working.glyphRing.color, lineWidth: TaskScreenStyle.Working.glyphRingWidth)
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(TaskScreenStyle.Working.glyphArc.color,
                                style: StrokeStyle(lineWidth: TaskScreenStyle.Working.glyphRingWidth, lineCap: .round))
                        .rotationEffect(.degrees(turns * 360))
                }
                .padding(TaskScreenStyle.Working.glyphMargin)
                .frame(width: TaskScreenStyle.Working.glyphSize + 2 * TaskScreenStyle.Working.glyphMargin,
                       height: TaskScreenStyle.Working.glyphSize + 2 * TaskScreenStyle.Working.glyphMargin)
                .padding(Self.pad)
                let expected = try #require(await reference(former, in: fixture))
                let view = LayerSpinnerView(spec: spec)
                let rendered = try #require(await candidate(view, size: expected.size, in: fixture) {
                    LayerMotion.withoutActions { view.turningLayer.transform = CATransform3DMakeRotation(turns * 2 * .pi, 0, 0, 1) }
                })
                // then
                #expect(view.intrinsicContentSize == CGSize(width: 16, height: 16))
                expectStrokeMatch(expected.bitmap, rendered, "glyph_\(name(appearance))_\(turns)")
            }
        }
    }

    // MARK: Pulse dot

    @Test func givenPulseDot_whenRenderedAtFixedOpacities_thenSizeAndColourMatchTheFormerCircle() async throws {
        for appearance in Self.appearances {
            for diameter in [HfRadius.Metrics.spacing8, HfRadius.Metrics.liveIndicatorDotSize] {
                // given
                let fixture = LayerMotionFixture(appearance: appearance)
                defer { fixture.close() }
                let view = LayerPulseDotView(diameter: diameter, color: Color.liveDot)
                #expect(view.intrinsicContentSize == CGSize(width: diameter, height: diameter))
                let size = CGSize(width: diameter + 2 * Self.pad, height: diameter + 2 * Self.pad)
                let full = try #require(await candidate(view, size: size, in: fixture))
                for opacity in [1.0, 0.3] {
                    // when
                    let expected = try #require(await reference(
                        Circle().fill(Color.liveDot).frame(width: diameter, height: diameter).opacity(opacity).padding(Self.pad), in: fixture))
                    let scaled = full.applyingOpacity(opacity)
                    // then
                    report("dot_\(name(appearance))_\(diameter)_\(opacity)", expected.bitmap, scaled)
                    expectSameBounds(expected.bitmap, scaled, "dot \(name(appearance)) \(diameter) \(opacity)")
                    #expect(expected.bitmap.meanDifference(from: scaled) <= Tolerance.shapeMean)
                    #expect(expected.bitmap.maxDifference(from: scaled) <= Tolerance.shapeMax)
                    let area = expected.bitmap.inkArea
                    #expect(abs(scaled.inkArea - area) / area <= Tolerance.shapeArea, "ink area \(scaled.inkArea) vs \(area)")
                    let colorExpected = expected.bitmap.strongestInkColor()
                    let colorDrawn = scaled.strongestInkColor()
                    print("LAYER_MOTION_MEASURED dot_colors \(name(appearance)) palette=\(resolved(Color.liveDot, appearance)) "
                        + "reference=\(String(describing: colorExpected)) drawn=\(String(describing: colorDrawn))")
                    if let colorExpected, let colorDrawn {
                        #expect(levels((colorExpected.red, colorExpected.green, colorExpected.blue, 1),
                                       (colorDrawn.red, colorDrawn.green, colorDrawn.blue, 1))
                            <= (opacity == 1 ? Tolerance.color : Tolerance.translucentColor))
                    } else {
                        Issue.record("blank dot raster")
                    }
                }
            }
        }
    }

    @Test func givenLiveStepLines_whenMounted_thenDotSizesMatchTheirIndicator() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let single = NSHostingView(rootView: LiveStepLineView(text: "Working"))
        single.frame = CGRect(x: 0, y: 0, width: 300, height: 30)
        let triple = NSHostingView(rootView: LiveStepLineView(text: "Working", indicator: .threeDots))
        triple.frame = CGRect(x: 0, y: 60, width: 300, height: 30)
        fixture.container.addSubview(single)
        fixture.container.addSubview(triple)
        // when
        await waitUntil {
            LayerMotionProbe.views(LayerPulseDotView.self, in: single).count == 1
                && LayerMotionProbe.views(LayerPulseDotView.self, in: triple).count == 3
        }
        // then
        let singleDiameters = LayerMotionProbe.views(LayerPulseDotView.self, in: single).map(\.diameter)
        let tripleDiameters = LayerMotionProbe.views(LayerPulseDotView.self, in: triple).map(\.diameter)
        #expect(singleDiameters == [HfRadius.Metrics.spacing8])
        #expect(tripleDiameters == Array(repeating: HfRadius.Metrics.liveIndicatorDotSize, count: 3))
        #expect(LayerMotionProbe.count(in: triple) == 3)
    }

    // MARK: Live appearance switch

    @Test func givenIndicatorsInWindow_whenWindowAppearanceSwitches_thenEachRepaintsWithTheOtherAppearancesColour() async throws {
        // given
        let fixture = LayerMotionFixture(appearance: .aqua)
        defer { fixture.close() }
        let font = NSFont.monospacedSystemFont(ofSize: HfTextStyle.body.pointSize, weight: .regular)
        let caret = LayerCaretView(font: font, color: Color.secondaryText)
        let spinner = LayerSpinnerView(spec: LayerSpinnerSpec(diameter: 12, lineWidth: 2, arcFraction: 0.3, period: 1,
                                                               ringColor: Color.runningFG, ringOpacity: 0.2, arcColor: Color.runningFG))
        let dot = LayerPulseDotView(diameter: 8, color: Color.liveDot)
        let wrapped = NSHostingView(rootView: FeedPulseDot(diameter: 8).environment(\.hfReduceMotionOverride, true))
        for (index, view) in [caret, spinner, dot, wrapped].enumerated() {
            view.frame.origin = CGPoint(x: 20 + 40 * CGFloat(index), y: 100)
            fixture.container.addSubview(view)
        }
        await waitUntil { !LayerMotionProbe.views(LayerPulseDotView.self, in: wrapped).isEmpty }
        let wrappedDot = try #require(LayerMotionProbe.views(LayerPulseDotView.self, in: wrapped).first)
        func colors() -> (arc: Color4?, dot: Color4?, wrapped: Color4?) {
            (cgColor((spinner.turningLayer as? CAShapeLayer)?.strokeColor), cgColor(dot.layer?.backgroundColor),
             cgColor(wrappedDot.layer?.backgroundColor))
        }
        func caretInk() throws -> Color4 {
            fixture.container.layoutSubtreeIfNeeded()
            let bitmap = try #require(LayerMotionRender.layerTree(of: fixture.container))
            // The container is non-flipped; its raster is top-down.
            let region = CGRect(x: caret.frame.minX, y: fixture.container.bounds.height - caret.frame.maxY,
                                width: caret.frame.width, height: caret.frame.height)
            return try #require(bitmap.strongestInkColor(in: region))
        }
        let light = colors()
        let lightCaret = try caretInk()
        // then: light colours
        let lightSecondary = resolved(Color.secondaryText, .aqua)
        let darkSecondary = resolved(Color.secondaryText, .darkAqua)
        #expect(levels(lightSecondary, darkSecondary) > 20, "the palette must differ between appearances for this test to prove anything")
        #expect(levels(lightCaret, lightSecondary) <= Tolerance.color, "light caret \(lightCaret) vs \(lightSecondary)")
        #expect(levels(try #require(light.arc), resolved(Color.runningFG, .aqua)) <= Tolerance.color)
        #expect(levels(try #require(light.dot), resolved(Color.liveDot, .aqua)) <= Tolerance.color)
        #expect(levels(try #require(light.wrapped), resolved(Color.liveDot, .aqua)) <= Tolerance.color)
        // when
        fixture.window.appearance = NSAppearance(named: .darkAqua)
        await waitUntil {
            levels(cgColor(dot.layer?.backgroundColor) ?? (0, 0, 0, 0), resolved(Color.liveDot, .darkAqua)) <= Tolerance.color
        }
        let dark = colors()
        let darkCaret = try caretInk()
        // then: every indicator now carries the dark colour
        #expect(levels(darkCaret, darkSecondary) <= Tolerance.color, "dark caret \(darkCaret) vs \(darkSecondary)")
        #expect(levels(try #require(dark.arc), resolved(Color.runningFG, .darkAqua)) <= Tolerance.color)
        #expect(levels(try #require(dark.dot), resolved(Color.liveDot, .darkAqua)) <= Tolerance.color)
        #expect(levels(try #require(dark.wrapped), resolved(Color.liveDot, .darkAqua)) <= Tolerance.color)
        #expect(levels(darkCaret, lightCaret) > 20)
        let ring = try #require(cgColor((spinner.trackLayer as? CAShapeLayer)?.strokeColor))
        let expectedRing = resolved(Color.runningFG, .darkAqua)
        #expect(levels(ring, expectedRing) <= Tolerance.color)
        #expect(abs(ring.alpha - expectedRing.alpha * 0.2) * 255 <= Tolerance.color)
        // when: and back
        fixture.window.appearance = NSAppearance(named: .aqua)
        await waitUntil {
            levels(cgColor(dot.layer?.backgroundColor) ?? (0, 0, 0, 0), resolved(Color.liveDot, .aqua)) <= Tolerance.color
        }
        // then
        #expect(levels(try #require(colors().dot), resolved(Color.liveDot, .aqua)) <= Tolerance.color)
        #expect(levels(try caretInk(), lightSecondary) <= Tolerance.color)
    }

    @Test func givenSwiftUIColourSchemeDiffersFromTheWindow_whenIndicatorsAreHosted_thenTheSwiftUIOverrideWinsForAll() async throws {
        // given: a light window, with a dark SwiftUI colour scheme on each indicator
        let fixture = LayerMotionFixture(appearance: .aqua)
        defer { fixture.close() }
        func hosted(_ view: some View, x: CGFloat) -> NSHostingView<AnyView> {
            let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark).environment(\.hfReduceMotionOverride, true)))
            host.frame = CGRect(x: x, y: 0, width: 40, height: 30)
            fixture.container.addSubview(host)
            return host
        }
        let caretHost = hosted(StreamingCaret(), x: 0)
        let spinnerHost = hosted(FeedRunningSpinner(), x: 50)
        let dotHost = hosted(FeedPulseDot(diameter: 8), x: 100)
        await waitUntil {
            !LayerMotionProbe.views(LayerCaretView.self, in: caretHost).isEmpty && !LayerMotionProbe.views(LayerSpinnerView.self, in: spinnerHost).isEmpty
                && !LayerMotionProbe.views(LayerPulseDotView.self, in: dotHost).isEmpty
        }
        let caret = try #require(LayerMotionProbe.views(LayerCaretView.self, in: caretHost).first)
        let spinner = try #require(LayerMotionProbe.views(LayerSpinnerView.self, in: spinnerHost).first)
        let dot = try #require(LayerMotionProbe.views(LayerPulseDotView.self, in: dotHost).first)
        let darkDot = resolved(Color.liveDot, .darkAqua)
        let darkArc = resolved(Color.runningFG, .darkAqua)
        let darkText = resolved(Color.secondaryText, .darkAqua)
        // when
        await waitUntil {
            levels(cgColor(dot.layer?.backgroundColor) ?? (0, 0, 0, 0), darkDot) <= Tolerance.color
                && levels(cgColor((spinner.turningLayer as? CAShapeLayer)?.strokeColor) ?? (0, 0, 0, 0), darkArc) <= Tolerance.color
                && caret.effectiveAppearance.name == .darkAqua
        }
        // then: SwiftUI applies its colour scheme to the hosted AppKit view as an appearance, so it wins
        // over the window's for the dot, the spinner and the caret.
        #expect(fixture.window.effectiveAppearance.name == .aqua)
        let drawnDot = try #require(cgColor(dot.layer?.backgroundColor))
        #expect(levels(drawnDot, darkDot) <= Tolerance.color, "dot: the SwiftUI colour scheme wins over the window appearance")
        let drawnArc = try #require(cgColor((spinner.turningLayer as? CAShapeLayer)?.strokeColor))
        let drawnRing = try #require(cgColor((spinner.trackLayer as? CAShapeLayer)?.strokeColor))
        #expect(levels(drawnArc, darkArc) <= Tolerance.color, "spinner arc: the SwiftUI colour scheme wins")
        #expect(levels(drawnRing, darkArc) <= Tolerance.color, "spinner ring: the SwiftUI colour scheme wins")
        #expect(caret.effectiveAppearance.name == .darkAqua, "caret view takes the dark appearance")
        let ink = try #require(LayerMotionRender.display(of: caret)?.strongestInkColor(), "the caret must draw")
        #expect(levels((ink.red, ink.green, ink.blue, 1), darkText) <= Tolerance.color, "caret ink \(ink) vs dark \(darkText)")
        #expect(levels(resolved(Color.liveDot, .aqua), darkDot) > 20)
        #expect(levels(resolved(Color.runningFG, .aqua), darkArc) > 20)
        #expect(levels(resolved(Color.secondaryText, .aqua), darkText) > 20)
    }
}
