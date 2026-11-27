//
//  ShimmerLayer.swift
//  HfUI
//
//  The shimmer in Core Animation. The sweep is a keyframe animation on a gradient layer; the Reduce
//  Motion pulse is an opacity animation on a layer filled with the placeholder tone. Both run in the
//  render server, so a loading placeholder adds no SwiftUI update per frame.
//

import AppKit
import SwiftUI

// MARK: - ShimmerTiming

/// The shimmer's timing and curves, shared by the layer and the tests.
enum ShimmerTiming {
    /// One sweep, in seconds.
    static let sweepPeriod: TimeInterval = 1.4
    /// One way of the Reduce Motion pulse; the full cycle is twice this.
    static let pulseHalfPeriod: TimeInterval = 0.8
    /// The dimmest the Reduce Motion pulse gets.
    static let pulseLowOpacity: Float = 0.55
    /// Samples across one sweep.
    static let sweepSteps = 28

    /// The sheen's offset as a fraction of the view's width, `u` through the sweep (0 to 1): the
    /// cosine ease from -1 (fully left of the view) to +1 (fully right).
    static func sweepOffset(atFraction fraction: Double) -> Double { -cos(fraction * .pi) }

    /// The sweep's `transform.translation.x` keyframes for a view `width` points wide.
    static func sweepValues(width: CGFloat) -> [CGFloat] {
        (0 ... sweepSteps).map { CGFloat(sweepOffset(atFraction: Double($0) / Double(sweepSteps))) * width }
    }
}

// MARK: - HfShimmerLayerView

/// An overlay that sweeps a sheen across its bounds, or, under Reduce Motion, pulses a fill of the
/// placeholder tone. Decorative: it takes no clicks and exposes nothing to accessibility.
public final class HfShimmerLayerView: HfLayerAnimatedView {
    /// What the view animates.
    public enum Mode: Equatable, Sendable {
        /// A highlight sweeping left to right every 1.4 s.
        case sweep
        /// The placeholder tone fading between full and 55% opacity every 1.6 s.
        case pulse
    }

    /// The key of the sweep's translation animation.
    public static let sweepKey = "hfShimmerSweep"
    /// The key of the pulse's opacity animation.
    public static let pulseKey = "hfShimmerPulse"

    private let sheenLayer = CAGradientLayer()
    private let pulseLayer = CALayer()
    private var installedWidth: CGFloat = 0
    private let outlineLayer = CAShapeLayer()

    /// Limits the sheen to the filled area of this path, in the view's top-left coordinate space.
    /// `nil` shows the whole bounds.
    public var maskPath: CGPath? {
        didSet {
            guard maskPath != oldValue else { return }
            needsLayout = true
        }
    }

    /// The corner radius the overlay is clipped to, so the sheen or the pulse never shows square corners over
    /// a rounded placeholder. A layer-backed overlay cannot be relied on to follow a SwiftUI `.clipShape`.
    public var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsLayout = true
        }
    }

    /// The current mode. A change swaps the animation when it is installed.
    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            reinstallMotion()
            syncVisibility()
        }
    }

    public init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        layer?.masksToBounds = true
        sheenLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sheenLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(sheenLayer)
        layer?.addSublayer(pulseLayer)
        animates = true
        syncVisibility()
        applyColors()
    }

    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        HfLayerClock.withoutActions {
            sheenLayer.frame = bounds
            pulseLayer.frame = bounds
            layer?.cornerRadius = cornerRadius
            let scale = window?.backingScaleFactor ?? outlineLayer.contentsScale
            outlineLayer.contentsScale = scale
            sheenLayer.contentsScale = scale
            pulseLayer.contentsScale = scale
            if let maskPath {
                // Layer coordinates are y-up unless AppKit flips the backing layer's geometry.
                var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
                outlineLayer.frame = bounds
                outlineLayer.path = layer?.isGeometryFlipped == true ? maskPath : maskPath.copy(using: &flip)
                outlineLayer.fillColor = NSColor.black.cgColor
                layer?.mask = outlineLayer
            } else {
                layer?.mask = nil
            }
        }
        // The sweep's keyframes span the view's width; a new width needs new keyframes.
        if isMotionInstalled, mode == .sweep, installedWidth != bounds.width { reinstallMotion() }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        needsLayout = true
    }

    private func syncVisibility() {
        HfLayerClock.withoutActions {
            sheenLayer.isHidden = mode != .sweep
            pulseLayer.isHidden = mode != .pulse
        }
    }

    private func applyColors() {
        let sheen = NSColor(Color.skeletonSheen)
        let fill = NSColor(Color.skeletonFill)
        HfLayerClock.withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                sheenLayer.colors = [sheen.withAlphaComponent(0).cgColor, sheen.cgColor, sheen.withAlphaComponent(0).cgColor]
                pulseLayer.backgroundColor = fill.cgColor
            }
        }
    }

    override func installMotion() {
        switch mode {
        case .sweep:
            sheenLayer.removeAnimation(forKey: Self.sweepKey)
            installedWidth = bounds.width
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            animation.values = ShimmerTiming.sweepValues(width: bounds.width)
            animation.duration = ShimmerTiming.sweepPeriod
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            animation.isRemovedOnCompletion = false
            animation.beginTime = HfLayerClock.beginTime(for: sheenLayer, period: ShimmerTiming.sweepPeriod)
            sheenLayer.add(animation, forKey: Self.sweepKey)
        case .pulse:
            pulseLayer.removeAnimation(forKey: Self.pulseKey)
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = ShimmerTiming.pulseLowOpacity
            animation.duration = ShimmerTiming.pulseHalfPeriod
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = false
            animation.beginTime = HfLayerClock.beginTime(for: pulseLayer, period: 2 * ShimmerTiming.pulseHalfPeriod)
            pulseLayer.add(animation, forKey: Self.pulseKey)
        }
    }

    override func removeMotion() {
        sheenLayer.removeAnimation(forKey: Self.sweepKey)
        pulseLayer.removeAnimation(forKey: Self.pulseKey)
    }

    /// The sheen layer, for inspection in tests.
    public var sweepLayer: CALayer { sheenLayer }

    /// The pulsing fill layer, for inspection in tests.
    public var fillLayer: CALayer { pulseLayer }
}

// MARK: - ShimmerLayer

/// The representable under `ShimmerModifier`. It takes whatever size its parent gives it and never
/// proposes one of its own.
struct ShimmerLayer: NSViewRepresentable {
    let mode: HfShimmerLayerView.Mode
    var maskPath: Path?
    var cornerRadius: CGFloat = 0

    func makeNSView(context _: Context) -> HfShimmerLayerView {
        let view = HfShimmerLayerView(mode: mode)
        view.maskPath = maskPath?.cgPath
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: HfShimmerLayerView, context _: Context) {
        if view.mode != mode { view.mode = mode }
        view.cornerRadius = cornerRadius
        let path = maskPath?.cgPath
        if view.maskPath != path { view.maskPath = path }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: HfShimmerLayerView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
