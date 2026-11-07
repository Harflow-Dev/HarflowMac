import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

/// Hosted behaviour of the layer-motion views: the animation values and the add/remove lifecycle,
/// directly and through the SwiftUI wrappers.
@MainActor @Suite(.serialized) struct LayerMotionAnimationHostedTests {
    private static let spec = LayerSpinnerSpec(diameter: 12, lineWidth: 2, arcFraction: 0.3, period: 1,
                                               ringColor: .blue, ringOpacity: 0.2, arcColor: .blue)

    private func caret() -> LayerCaretView {
        LayerCaretView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), color: .gray)
    }

    private func mount(_ view: NSView, in fixture: LayerMotionFixture) {
        view.frame.origin = CGPoint(x: 20, y: 20)
        fixture.container.addSubview(view)
    }

    private func hostWrapper(_ root: some View, in fixture: LayerMotionFixture) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = fixture.container.bounds
        fixture.container.addSubview(host)
        return host
    }

    // MARK: Values

    @Test func givenCaretInWindow_whenAnimationIsRead_thenKeyframesFollowTheCurveAtThePeriod() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = caret()
        view.animates = true
        // when
        mount(view, in: fixture)
        // then
        let layer = try #require(view.layer)
        #expect(layer.animationKeys() == [LayerCaretView.animationKey])
        let animation = try #require(layer.animation(forKey: LayerCaretView.animationKey) as? CAKeyframeAnimation)
        let values = try #require(animation.values as? [Double])
        #expect(values.count == LayerCaretView.keyframeSteps + 1)
        for (index, value) in values.enumerated() {
            let expected = StreamingCaret.opacity(atPhase: StreamingCaret.period * Double(index) / Double(LayerCaretView.keyframeSteps))
            #expect(abs(value - expected) < 1e-12)
        }
        #expect(animation.duration == StreamingCaret.period)
        #expect(animation.repeatCount == .infinity)
        #expect(animation.calculationMode == .linear)
        #expect(animation.keyPath == "opacity")
        #expect(animation.isRemovedOnCompletion == false)
        #expect(animation.autoreverses == false)
    }

    @Test func givenCaretInWindow_whenPhaseIsRead_thenItEqualsTheReferenceDatePhase() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = caret()
        view.animates = true
        mount(view, in: fixture)
        // when
        let layer = try #require(view.layer)
        let animation = try #require(layer.animation(forKey: LayerCaretView.animationKey))
        // then: the local time and the reference-date phase agree to well within one frame.
        let error = LayerMotionProbe.phaseError(layer: layer, animation: animation, period: StreamingCaret.period)
        #expect(error < 0.05, "phase error \(error)")
        print("LAYER_MOTION_MEASURED caret_phase_error_s=\(error)")
    }

    @Test func givenSpinnerInWindow_whenAnimationIsRead_thenItTurnsOnceASecondClockwise() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerSpinnerView(spec: Self.spec)
        view.animates = true
        // when
        mount(view, in: fixture)
        view.layoutSubtreeIfNeeded()
        // then
        let arc = view.turningLayer
        let animation = try #require(arc.animation(forKey: LayerSpinnerView.animationKey) as? CABasicAnimation)
        #expect(animation.keyPath == "transform.rotation.z")
        #expect(animation.fromValue as? Double == 0)
        #expect(abs((animation.toValue as? Double ?? 0) - 2 * .pi) < 1e-12)
        #expect(animation.duration == 1)
        #expect(animation.repeatCount == .infinity)
        #expect(animation.isRemovedOnCompletion == false)
        #expect(animation.timingFunction?.controlValues == CAMediaTimingFunction(name: .linear).controlValues)
        let error = LayerMotionProbe.phaseError(layer: arc, animation: animation, period: 1)
        #expect(error < 0.05, "phase error \(error)")
        // Clockwise on screen: a positive turn takes the 3 o'clock point of the arc layer to 6 o'clock in
        // the view's top-left coordinate space, which is what the root layer shows.
        let root = try #require(view.layer)
        let right = CGPoint(x: arc.bounds.maxX, y: arc.bounds.midY)
        let before = arc.convert(right, to: root)
        LayerMotion.withoutActions { arc.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1) }
        let after = arc.convert(right, to: root)
        LayerMotion.withoutActions { arc.transform = CATransform3DIdentity }
        let center = arc.convert(CGPoint(x: arc.bounds.midX, y: arc.bounds.midY), to: root)
        #expect(before.x > center.x && abs(before.y - center.y) < 0.01)
        #expect(abs(after.x - center.x) < 0.01)
        let downIsLarger = root.isGeometryFlipped ? after.y > center.y : after.y < center.y
        #expect(downIsLarger, "a positive rotation must carry 3 o'clock to 6 o'clock")
    }

    @Test func givenSpinnerAnimating_whenLayersAreRead_thenOnlyTheOwnedArcSublayerCarriesIt() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerSpinnerView(spec: Self.spec)
        view.animates = true
        // when
        mount(view, in: fixture)
        view.layoutSubtreeIfNeeded()
        // then
        #expect(view.layer?.animationKeys() == nil)
        #expect(view.trackLayer.animationKeys() == nil)
        #expect(view.turningLayer.animationKeys() == [LayerSpinnerView.animationKey])
        #expect(view.turningLayer.superlayer === view.layer)
        #expect(view.turningLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        let bounds = view.bounds
        #expect(view.turningLayer.position == CGPoint(x: bounds.midX, y: bounds.midY))
        #expect(view.turningLayer.bounds.size == CGSize(width: 12, height: 12))
    }

    @Test func givenSpinnerResized_whenLaidOut_thenTheArcLayerIsRecentred() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerSpinnerView(spec: Self.spec)
        view.animates = true
        mount(view, in: fixture)
        view.layoutSubtreeIfNeeded()
        // when
        view.frame.size = CGSize(width: 30, height: 30)
        view.layoutSubtreeIfNeeded()
        // then
        #expect(view.turningLayer.position == CGPoint(x: 15, y: 15))
        #expect(view.turningLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(view.turningLayer.animationKeys() == [LayerSpinnerView.animationKey])
    }

    @Test func givenPulseInWindow_whenAnimationIsRead_thenItEasesToThirtyPercentOverEightTenths() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerPulseDotView(diameter: 8, color: .green)
        view.animates = true
        // when
        mount(view, in: fixture)
        // then
        let layer = try #require(view.layer)
        let animation = try #require(layer.animation(forKey: LayerPulseDotView.animationKey) as? CABasicAnimation)
        #expect(animation.keyPath == "opacity")
        #expect(animation.fromValue as? Double == 1)
        #expect(Float(animation.toValue as? Double ?? 0) == 0.3)
        #expect(animation.duration == 0.8)
        #expect(animation.autoreverses)
        #expect(animation.repeatCount == .infinity)
        #expect(animation.isRemovedOnCompletion == false)
        #expect(animation.timingFunction?.controlValues == CAMediaTimingFunction(name: .easeInEaseOut).controlValues)
        let error = LayerMotionProbe.phaseError(layer: layer, animation: animation, period: 1.6)
        #expect(error < 0.05, "phase error \(error)")
    }

    // MARK: Lifecycle, direct

    @Test func givenAnimatingViewOutsideWindow_whenEnteringAndLeaving_thenOneAnimationIsAddedAndRemoved() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let views: [LayerMotionView] = [caret(), LayerSpinnerView(spec: Self.spec), LayerPulseDotView(diameter: 8, color: .green)]
        for view in views {
            view.animates = true
            #expect(view.isMotionInstalled == false, "no animation without a window")
            // when
            mount(view, in: fixture)
            // then
            #expect(view.isMotionInstalled)
            #expect(LayerMotionProbe.count(in: view) == 1, "\(type(of: view))")
            // when
            view.removeFromSuperview()
            // then
            #expect(view.isMotionInstalled == false)
            #expect(LayerMotionProbe.count(in: view) == 0)
        }
    }

    @Test func givenCaretLeavesWindow_whenRead_thenStaticLookIsRestored() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = caret()
        view.animates = true
        mount(view, in: fixture)
        let layer = try #require(view.layer)
        LayerMotion.withoutActions { layer.opacity = 0.4 }
        // when
        view.removeFromSuperview()
        // then
        #expect(layer.animationKeys() == nil)
        #expect(layer.opacity == 1)
    }

    @Test func givenPulseLeavesWindow_whenRead_thenStaticLookIsRestored() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerPulseDotView(diameter: 8, color: .green)
        view.animates = true
        mount(view, in: fixture)
        let layer = try #require(view.layer)
        LayerMotion.withoutActions { layer.opacity = 0.5 }
        // when
        view.removeFromSuperview()
        // then
        #expect(layer.animationKeys() == nil)
        #expect(layer.opacity == 1)
    }

    @Test func givenViewInWindow_whenFlagTogglesOffAndOn_thenAnimationFollowsTheFlag() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let views: [LayerMotionView] = [caret(), LayerSpinnerView(spec: Self.spec), LayerPulseDotView(diameter: 8, color: .green)]
        for view in views {
            mount(view, in: fixture)
            #expect(LayerMotionProbe.count(in: view) == 0, "not animating until asked: \(type(of: view))")
            // when
            view.animates = true
            // then
            #expect(LayerMotionProbe.count(in: view) == 1)
            // when
            view.animates = false
            // then
            #expect(LayerMotionProbe.count(in: view) == 0)
            #expect(view.isMotionInstalled == false)
            // when
            view.animates = true
            // then
            #expect(LayerMotionProbe.count(in: view) == 1)
        }
    }

    @Test func givenAnimatingView_whenFlagIsSetToItsCurrentValue_thenTheAnimationIsUntouched() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = caret()
        view.animates = true
        mount(view, in: fixture)
        let layer = try #require(view.layer)
        let installed = try #require(layer.animation(forKey: LayerCaretView.animationKey))
        // when
        view.animates = true
        // then
        #expect(layer.animation(forKey: LayerCaretView.animationKey) === installed)
        #expect(layer.animationKeys()?.count == 1)
    }

    @Test func givenAnimatingView_whenMovedBetweenWindows_thenExactlyOneAnimationRemains() throws {
        // given
        let first = LayerMotionFixture()
        let second = LayerMotionFixture()
        defer { first.close(); second.close() }
        let views: [LayerMotionView] = [caret(), LayerSpinnerView(spec: Self.spec), LayerPulseDotView(diameter: 8, color: .green)]
        for view in views {
            view.animates = true
            mount(view, in: first)
            // when
            second.container.addSubview(view)
            // then
            #expect(view.window === second.window)
            #expect(view.isMotionInstalled)
            #expect(LayerMotionProbe.count(in: view) == 1, "\(type(of: view))")
            // when: and back through no window at all
            view.removeFromSuperview()
            #expect(LayerMotionProbe.count(in: view) == 0)
            first.container.addSubview(view)
            #expect(LayerMotionProbe.count(in: view) == 1)
        }
    }

    @Test func givenAnimatingSpinner_whenSpecChanges_thenOneAnimationRemainsAndEqualSpecIsIgnored() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerSpinnerView(spec: Self.spec)
        view.animates = true
        mount(view, in: fixture)
        let installed = view.turningLayer.animation(forKey: LayerSpinnerView.animationKey)
        // when: an equal spec
        view.spec = Self.spec
        // then
        #expect(view.turningLayer.animation(forKey: LayerSpinnerView.animationKey) === installed)
        // when: a different spec
        var changed = Self.spec
        changed.period = 2
        view.spec = changed
        // then
        #expect(view.turningLayer.animationKeys() == [LayerSpinnerView.animationKey])
        let animation = view.turningLayer.animation(forKey: LayerSpinnerView.animationKey)
        #expect(animation !== installed)
        #expect(animation?.duration == 2)
    }

    @Test func givenIdleSpinner_whenSpecChanges_thenNoAnimationIsAdded() throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerSpinnerView(spec: Self.spec)
        mount(view, in: fixture)
        // when
        var changed = Self.spec
        changed.diameter = 16
        view.spec = changed
        // then
        #expect(LayerMotionProbe.count(in: view) == 0)
        #expect(view.intrinsicContentSize == CGSize(width: 16, height: 16))
    }

    // MARK: Lifecycle, through the wrappers

    @Test func givenCaretWrapper_whenReduceMotionOverrideTogglesLive_thenAnimationFollows() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(StreamingCaret().environment(\.hfReduceMotionOverride, false), in: fixture)
        await waitUntil { !LayerMotionProbe.views(LayerCaretView.self, in: host).isEmpty }
        let view = try #require(LayerMotionProbe.views(LayerCaretView.self, in: host).first)
        await waitUntil { view.isMotionInstalled }
        #expect(LayerMotionProbe.count(in: host) == 1)
        // when: Reduce Motion on
        host.rootView = AnyView(StreamingCaret().environment(\.hfReduceMotionOverride, true))
        await waitUntil { !view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 0)
        #expect(view.layer?.opacity == 1)
        #expect(LayerMotionProbe.views(LayerCaretView.self, in: host).first === view, "the same view is updated, not remounted")
        // when: off again
        host.rootView = AnyView(StreamingCaret().environment(\.hfReduceMotionOverride, false))
        await waitUntil { view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 1)
    }

    @Test func givenSpinnerWrapper_whenReduceMotionOverrideTogglesLive_thenAnimationFollows() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(FeedRunningSpinner().environment(\.hfReduceMotionOverride, true), in: fixture)
        await waitUntil { !LayerMotionProbe.views(LayerSpinnerView.self, in: host).isEmpty }
        let view = try #require(LayerMotionProbe.views(LayerSpinnerView.self, in: host).first)
        #expect(LayerMotionProbe.count(in: host) == 0, "Reduce Motion holds the arc still")
        // when
        host.rootView = AnyView(FeedRunningSpinner().environment(\.hfReduceMotionOverride, false))
        await waitUntil { view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 1)
        // when
        host.rootView = AnyView(FeedRunningSpinner().environment(\.hfReduceMotionOverride, true))
        await waitUntil { !view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 0)
    }

    @Test func givenWorkingGlyphWrapper_whenReduceMotionOverrideTogglesLive_thenAnimationFollows() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(TranscriptWorkingGlyph().environment(\.hfReduceMotionOverride, false), in: fixture)
        await waitUntil { LayerMotionProbe.count(in: host) == 1 }
        #expect(LayerMotionProbe.count(in: host) == 1)
        let view = try #require(LayerMotionProbe.views(LayerSpinnerView.self, in: host).first)
        // when
        host.rootView = AnyView(TranscriptWorkingGlyph().environment(\.hfReduceMotionOverride, true))
        await waitUntil { !view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 0)
        // when
        host.rootView = AnyView(TranscriptWorkingGlyph().environment(\.hfReduceMotionOverride, false))
        await waitUntil { view.isMotionInstalled }
        #expect(LayerMotionProbe.count(in: host) == 1)
    }

    @Test func givenPulseDotWrapper_whenReduceMotionOverrideTogglesLive_thenAnimationFollows() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(FeedPulseDot(diameter: 8).environment(\.hfReduceMotionOverride, false), in: fixture)
        await waitUntil { LayerMotionProbe.count(in: host) == 1 }
        let view = try #require(LayerMotionProbe.views(LayerPulseDotView.self, in: host).first)
        #expect(LayerMotionProbe.count(in: host) == 1)
        // when
        host.rootView = AnyView(FeedPulseDot(diameter: 8).environment(\.hfReduceMotionOverride, true))
        await waitUntil { !view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 0)
        #expect(view.layer?.opacity == 1)
    }

    @Test func givenCaretWrapper_whenBlinkFlagFlips_thenAnimationFollowsWithoutRemount() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(StreamingCaretLayer(blinks: false), in: fixture)
        await waitUntil { !LayerMotionProbe.views(LayerCaretView.self, in: host).isEmpty }
        let view = try #require(LayerMotionProbe.views(LayerCaretView.self, in: host).first)
        #expect(LayerMotionProbe.count(in: host) == 0)
        // when
        host.rootView = AnyView(StreamingCaretLayer(blinks: true))
        await waitUntil { view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 1)
        // when
        host.rootView = AnyView(StreamingCaretLayer(blinks: false))
        await waitUntil { !view.isMotionInstalled }
        // then
        #expect(LayerMotionProbe.count(in: host) == 0)
        #expect(LayerMotionProbe.views(LayerCaretView.self, in: host).first === view)
    }

    @Test func givenWrapperInWindow_whenHostMovesBetweenWindows_thenOneAnimationRemains() async throws {
        // given
        let first = LayerMotionFixture()
        let second = LayerMotionFixture()
        defer { first.close(); second.close() }
        let host = hostWrapper(StreamingCaret().environment(\.hfReduceMotionOverride, false), in: first)
        await waitUntil { LayerMotionProbe.count(in: host) == 1 }
        #expect(LayerMotionProbe.count(in: host) == 1)
        // when
        second.container.addSubview(host)
        // then
        #expect(host.window === second.window)
        #expect(LayerMotionProbe.count(in: host) == 1)
        // when
        host.removeFromSuperview()
        // then
        #expect(LayerMotionProbe.count(in: host) == 0)
    }
}
