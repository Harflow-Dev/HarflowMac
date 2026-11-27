//
//  HfLayerMotion.swift
//  HfUI
//
//  Shared pieces for HfUI's Core Animation indicators (the running spinner and the shimmer). A
//  SwiftUI `TimelineView` keeps its graph pending every frame, and each pending update climbs to the
//  platform host that owns the view, which then re-measures the whole window root. A layer animation
//  runs in the render server instead: no SwiftUI update per frame, and nothing commits while the
//  window is off screen.
//

import AppKit

// MARK: - HfLayerClock

/// Timing helpers shared by the layer-driven indicators.
enum HfLayerClock {
    /// The layer-time `beginTime` that puts an animation of `period` at the same phase as the
    /// reference-date clock (`phase = referenceDate mod period`). Re-derived on every add, so
    /// indicators mounted at different moments agree with each other and with the clocks they replace.
    static func beginTime(layerTime: CFTimeInterval, referenceDate: TimeInterval, period: TimeInterval) -> CFTimeInterval {
        layerTime - referenceDate.truncatingRemainder(dividingBy: period)
    }

    /// `beginTime(layerTime:referenceDate:period:)` for the current instant on `layer`'s time space.
    static func beginTime(for layer: CALayer, period: TimeInterval) -> CFTimeInterval {
        beginTime(layerTime: layer.convertTime(CACurrentMediaTime(), from: nil),
                  referenceDate: Date().timeIntervalSinceReferenceDate,
                  period: period)
    }

    /// Runs `body` without Core Animation's implicit 0.25 second property animations.
    static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - HfLayerAnimatedView

/// A layer-backed view that owns repeating animations. They are added or removed only on a
/// transition: the view entering or leaving a window, or `animates` flipping. Setting `animates` to
/// its current value, or moving between windows, does nothing.
public class HfLayerAnimatedView: NSView {
    /// Whether the indicator should move. Reduce Motion drives this to `false`.
    public final var animates = false {
        didSet { if animates != oldValue { syncMotion() } }
    }

    /// Whether the animations are currently on the layers.
    public private(set) final var isMotionInstalled = false

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The owning SwiftUI wrapper decides what, if anything, the indicator exposes.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) { nil }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncMotion()
    }

    /// Decorative: never takes clicks from the content it sits on.
    override public func hitTest(_: NSPoint) -> NSView? { nil }

    private func syncMotion() {
        let shouldRun = animates && window != nil
        guard shouldRun != isMotionInstalled else { return }
        isMotionInstalled = shouldRun
        if shouldRun { installMotion() } else { removeMotion() }
    }

    /// Removes and re-adds the animations when they are installed; does nothing otherwise. For a
    /// change of mode or geometry that the existing animations no longer match.
    final func reinstallMotion() {
        guard isMotionInstalled else { return }
        removeMotion()
        installMotion()
    }

    /// Adds the animations. Called only on the transition to running, with the view in a window.
    func installMotion() {}

    /// Removes the animations and restores the static look.
    func removeMotion() {}
}
