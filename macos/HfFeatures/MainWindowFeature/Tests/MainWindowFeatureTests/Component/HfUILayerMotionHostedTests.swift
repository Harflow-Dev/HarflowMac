import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - CountingHostingView

/// A root hosting view that counts how often AppKit lays it out, updates its constraints and invalidates its fitting size.
private final class CountingHostingView: NSHostingView<AnyView> {
    private(set) var layoutCalls = 0
    private(set) var invalidations = 0
    private(set) var constraintUpdates = 0

    override func updateConstraints() {
        constraintUpdates += 1
        super.updateConstraints()
    }

    override func layout() {
        layoutCalls += 1
        super.layout()
    }

    override func invalidateIntrinsicContentSize() {
        invalidations += 1
        super.invalidateIntrinsicContentSize()
    }
}

/// Hosted behaviour of the Core Animation indicators that live in HfUI (the running spinner and the
/// shimmer) and of the running workflow outline: the animation values, the add/remove lifecycle and
/// the SwiftUI wrappers' Reduce Motion and accessibility behaviour.
@MainActor @Suite(.serialized) struct HfUILayerMotionHostedTests {
    private func hostWrapper(_ root: some View, in fixture: LayerMotionFixture) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = fixture.container.bounds
        fixture.container.addSubview(host)
        return host
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        LayerMotionProbe.views(type, in: root)
    }

    // MARK: Spinner

    @Test func givenLayerSpinner_whenMovedToWindow_thenAddsOneSecondRotation() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(RunningSpinner().environment(\.hfReduceMotionOverride, false), in: fixture)

        // when
        await waitUntil { descendants(HfLayerSpinnerView.self, in: host).first?.isMotionInstalled == true }

        // then
        let view = try #require(descendants(HfLayerSpinnerView.self, in: host).first)
        let animation = try #require(view.turningLayer.animation(forKey: HfLayerSpinnerView.animationKey) as? CABasicAnimation)
        #expect(animation.keyPath == "transform.rotation.z")
        #expect(animation.duration == 1)
        #expect(animation.repeatCount == .infinity)
        #expect(animation.isRemovedOnCompletion == false)
        #expect(view.trackLayer.animationKeys() == nil)
        let error = LayerMotionProbe.phaseError(layer: view.turningLayer, animation: animation, period: 1)
        #expect(error < 0.05, "phase error \(error)")
    }

    @Test func givenReduceMotionOverride_whenSpinnerMounted_thenShowsStaticArcWithoutAnimation() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }

        // when
        let host = hostWrapper(RunningSpinner().environment(\.hfReduceMotionOverride, true), in: fixture)
        await waitUntil { !descendants(HfLayerSpinnerView.self, in: host).isEmpty }

        // then
        let view = try #require(descendants(HfLayerSpinnerView.self, in: host).first)
        #expect(!view.isMotionInstalled)
        #expect(view.turningLayer.animationKeys() == nil)
    }

    @Test func givenSpinner_whenReduceMotionOverrideTogglesLive_thenAnimationFollows() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(RunningSpinner().environment(\.hfReduceMotionOverride, true), in: fixture)
        await waitUntil { !descendants(HfLayerSpinnerView.self, in: host).isEmpty }
        let view = try #require(descendants(HfLayerSpinnerView.self, in: host).first)

        // when
        host.rootView = AnyView(RunningSpinner().environment(\.hfReduceMotionOverride, false))
        await waitUntil { view.isMotionInstalled }

        // then
        #expect(view.turningLayer.animationKeys() == [HfLayerSpinnerView.animationKey])

        // when
        host.rootView = AnyView(RunningSpinner().environment(\.hfReduceMotionOverride, true))
        await waitUntil { !view.isMotionInstalled }

        // then
        #expect(view.turningLayer.animationKeys() == nil)
    }

    private func runningLabels(in host: NSView) -> [String] {
        var seen = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let text = object.perform(selector)?.takeUnretainedValue() as? String {
                    labels.append(text)
                }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return }
            for child in children { if let child = child as? NSObject { visit(child) } }
        }
        for child in host.accessibilityChildren() ?? [] { if let child = child as? NSObject { visit(child) } }
        return labels
    }

    @Test func givenRunningSpinner_whenRenderedWithoutCallerOverride_thenExposesRunningElement() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        fixture.enableAccessibility()
        let host = hostWrapper(RunningSpinner().environment(\.hfReduceMotionOverride, true), in: fixture)

        // when
        await waitUntil { runningLabels(in: host).contains("Running") }

        // then
        #expect(runningLabels(in: host).filter { $0 == "Running" }.count == 1)
    }

    @Test func givenCallerHidesSpinner_whenRendered_thenNoRunningElement() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        fixture.enableAccessibility()
        let host = hostWrapper(RunningSpinner().accessibilityHidden(true).environment(\.hfReduceMotionOverride, true), in: fixture)

        // when
        await waitUntil { !descendants(HfLayerSpinnerView.self, in: host).isEmpty }

        // then
        #expect(!runningLabels(in: host).contains("Running"))
    }

    // MARK: Shimmer

    private func placeholder(_ override: Bool?) -> some View {
        Color.skeletonFill
            .shimmering()
            .frame(width: 120, height: 20)
            .environment(\.shimmerReduceMotionOverride, override)
    }

    @Test func givenShimmerLayerView_whenMovedToWindow_thenAddsSweepKeyframesOverOnePointFourSeconds() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(placeholder(false), in: fixture)

        // when
        await waitUntil {
            descendants(HfShimmerLayerView.self, in: host).first.map { $0.isMotionInstalled && $0.sweepLayer.frame.width == 120 } == true
        }

        // then
        let view = try #require(descendants(HfShimmerLayerView.self, in: host).first)
        #expect(view.sweepLayer.frame.width == 120)
        #expect(view.mode == .sweep)
        let animation = try #require(view.sweepLayer.animation(forKey: HfShimmerLayerView.sweepKey) as? CAKeyframeAnimation)
        #expect(animation.keyPath == "transform.translation.x")
        #expect(animation.duration == 1.4)
        #expect(animation.repeatCount == .infinity)
        let values = try #require(animation.values as? [CGFloat])
        let first = try #require(values.first)
        let last = try #require(values.last)
        #expect(abs(first + 120) < 0.5 && abs(last - 120) < 0.5)
        #expect(view.fillLayer.animationKeys() == nil)
        let error = LayerMotionProbe.phaseError(layer: view.sweepLayer, animation: animation, period: 1.4)
        #expect(error < 0.05, "phase error \(error)")
    }

    @Test func givenShimmerReduceMotion_whenMovedToWindow_thenAddsOpacityPulseFromOneToPointFiveFive() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let host = hostWrapper(placeholder(true), in: fixture)

        // when
        await waitUntil { descendants(HfShimmerLayerView.self, in: host).first?.isMotionInstalled == true }

        // then
        let view = try #require(descendants(HfShimmerLayerView.self, in: host).first)
        #expect(view.mode == .pulse)
        let animation = try #require(view.fillLayer.animation(forKey: HfShimmerLayerView.pulseKey) as? CABasicAnimation)
        #expect(animation.keyPath == "opacity")
        #expect((animation.fromValue as? NSNumber)?.floatValue == 1)
        #expect((animation.toValue as? NSNumber)?.floatValue == 0.55)
        #expect(animation.duration == 0.8)
        #expect(animation.autoreverses)
        #expect(animation.repeatCount == .infinity)
        #expect(view.sweepLayer.animationKeys() == nil)
        let error = LayerMotionProbe.phaseError(layer: view.fillLayer, animation: animation, period: 1.6)
        #expect(error < 0.05, "phase error \(error)")
    }

    @Test func givenShimmerOverrideFalseUnderSystemReduceMotion_whenMounted_thenSweeps() async throws {
        // given — the override wins over whatever the system setting is
        let fixture = LayerMotionFixture()
        defer { fixture.close() }

        // when
        let host = hostWrapper(placeholder(false), in: fixture)
        await waitUntil { !descendants(HfShimmerLayerView.self, in: host).isEmpty }

        // then
        #expect(descendants(HfShimmerLayerView.self, in: host).first?.mode == .sweep)
    }

    @Test func givenWidthChange_whenLayout_thenGradientMatchesBounds() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = HfShimmerLayerView(mode: .sweep)
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
        fixture.container.addSubview(view)
        await waitUntil { view.isMotionInstalled && view.sweepLayer.frame.width == 100 }
        let first = try #require(view.sweepLayer.animation(forKey: HfShimmerLayerView.sweepKey) as? CAKeyframeAnimation)

        // when
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 20)
        view.layoutSubtreeIfNeeded()
        await waitUntil { view.sweepLayer.frame.width == 160 }

        // then
        #expect(view.sweepLayer.frame == view.bounds)
        let second = try #require(view.sweepLayer.animation(forKey: HfShimmerLayerView.sweepKey) as? CAKeyframeAnimation)
        let values = try #require(second.values as? [CGFloat])
        let last = try #require(values.last)
        #expect(first !== second)
        #expect(abs(last - 160) < 0.5)
    }

    @Test func givenRemovedFromWindow_whenObserved_thenAnimationsRemoved() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let sweep = HfShimmerLayerView(mode: .sweep)
        sweep.frame = CGRect(x: 0, y: 0, width: 40, height: 12)
        fixture.container.addSubview(sweep)
        let host = hostWrapper(RunningSpinner().environment(\.hfReduceMotionOverride, false), in: fixture)
        await waitUntil { descendants(HfLayerSpinnerView.self, in: host).first?.isMotionInstalled == true }
        let spinner = try #require(descendants(HfLayerSpinnerView.self, in: host).first)
        await waitUntil { sweep.isMotionInstalled }

        // when
        sweep.removeFromSuperview()
        host.removeFromSuperview()

        // then
        #expect(!sweep.isMotionInstalled && !spinner.isMotionInstalled)
        #expect(sweep.sweepLayer.animationKeys() == nil)
        #expect(spinner.turningLayer.animationKeys() == nil)
    }

    // MARK: Workflow outline

    @Test func givenRunningOutline_whenMovedToWindow_thenTurnsOnceEveryThreeSeconds() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerOutlineView(isSelected: true)
        view.frame = CGRect(x: 20, y: 20, width: 160, height: 80)
        view.animates = true

        // when
        fixture.container.addSubview(view)

        // then
        let animation = try #require(view.turningLayer.animation(forKey: LayerOutlineView.animationKey) as? CABasicAnimation)
        #expect(animation.keyPath == "transform.rotation.z")
        #expect(animation.duration == 3)
        #expect(animation.repeatCount == .infinity)
        #expect(view.layer?.mask === view.maskLayer)
    }

    @Test func givenRunningOutlineUnderReduceMotion_whenMounted_thenGradientIsStatic() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let view = LayerOutlineView(isSelected: false)
        view.frame = CGRect(x: 20, y: 20, width: 160, height: 80)

        // when
        fixture.container.addSubview(view)

        // then
        #expect(!view.isMotionInstalled)
        #expect(view.turningLayer.animationKeys() == nil)
    }

    // MARK: Benchmark

    /// A skeleton and a running `StatusIcon`, and no clock of any kind (no `TaskStatusLabel`, no `TaskLiveClock`),
    /// so a 1 Hz tick cannot add to the counts.
    private var benchmarkFixture: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: 160, height: 14)
            SkeletonRows(count: 2)
            StatusIcon(status: .running)
        }
        .padding(16)
        .environment(\.hfReduceMotionOverride, false)
        .environment(\.shimmerReduceMotionOverride, false)
    }

    /// Mounts `content` in a counting root and returns the counts over a two second idle interval. The interval is
    /// a measurement, not a wait for a condition.
    private func idleCounts(of content: some View, in fixture: LayerMotionFixture) async throws -> (layouts: Int, invalidations: Int, updates: Int) {
        let host = CountingHostingView(rootView: AnyView(content))
        host.frame = fixture.container.bounds
        fixture.container.addSubview(host)
        await waitUntil {
            !descendants(HfShimmerLayerView.self, in: host).isEmpty && descendants(HfShimmerLayerView.self, in: host).allSatisfy(\.isMotionInstalled)
        }
        host.layoutSubtreeIfNeeded()
        let before = (host.layoutCalls, host.invalidations, host.constraintUpdates)
        try await Task.sleep(for: .seconds(2))
        return (host.layoutCalls - before.0, host.invalidations - before.1, host.constraintUpdates - before.2)
    }

    /// Before the change both indicators ran 30 Hz `TimelineView`s, which re-measured the root about 60 times a second.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARFLOW_NATIVE_SIDEBAR_BENCHMARK"] == "1"))
    func givenSkeletonAndRunningIcon_whenIdleTwoSeconds_thenRootPassesRunAtMostOnceEach() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }

        // when
        let counts = try await idleCounts(of: benchmarkFixture, in: fixture)

        // then
        print("HFUI_LAYER_MOTION_BENCHMARK layouts=\(counts.layouts) invalidations=\(counts.invalidations) constraint_updates=\(counts.updates)")
        #expect(counts.layouts <= 1, "root layout calls: \(counts.layouts)")
        #expect(counts.invalidations <= 1, "root invalidations: \(counts.invalidations)")
        #expect(counts.updates <= 1, "root constraint updates: \(counts.updates)")
    }

    /// The control: the same fixture plus a 30 Hz SwiftUI clock. If this does not exceed 20 passes in two seconds the
    /// counters cannot see the cost the benchmark claims to have removed, and the benchmark proves nothing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARFLOW_NATIVE_SIDEBAR_BENCHMARK"] == "1"))
    func givenSameFixtureWithA30HzTimeline_whenIdleTwoSeconds_thenRootPassesExceedTwenty() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let withClock = VStack(alignment: .leading, spacing: 0) {
            benchmarkFixture
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                Text("\(context.date.timeIntervalSinceReferenceDate)").font(.caption).hidden()
            }
        }

        // when
        let counts = try await idleCounts(of: withClock, in: fixture)

        // then
        print("HFUI_LAYER_MOTION_CONTROL layouts=\(counts.layouts) invalidations=\(counts.invalidations) constraint_updates=\(counts.updates)")
        #expect(counts.layouts + counts.invalidations + counts.updates > 20,
                "control saw layouts \(counts.layouts), invalidations \(counts.invalidations), updates \(counts.updates)")
    }
}
