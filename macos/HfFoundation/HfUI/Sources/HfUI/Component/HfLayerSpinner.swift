//
//  HfLayerSpinner.swift
//  HfUI
//
//  The running spinner drawn in Core Animation: a faint ring with a leading arc that turns once a
//  second in the render server. `RunningSpinner` (and so `StatusIcon`, `StatusBadge`, `LoadingLabel`
//  and the top bar badge) is this view, so a running task adds no SwiftUI update per frame.
//

import AppKit
import SwiftUI

// MARK: - HfLayerSpinnerSpec

/// The look of the spinner. Colours are SwiftUI values so equal specs compare equal and an unchanged
/// spec never touches the layers.
struct HfLayerSpinnerSpec: Equatable {
    /// The circle's diameter; the stroke is centred on its edge, as `Circle().stroke` is.
    var diameter: CGFloat
    var lineWidth: CGFloat
    /// The leading arc's share of the circle, drawn clockwise from 3 o'clock.
    var arcFraction: CGFloat = 0.3
    /// One full turn.
    var period: TimeInterval = 1
    var color: Color
    /// The ring's opacity relative to `color`.
    var ringOpacity: Double = 0.2
}

// MARK: - HfLayerSpinnerView

/// A ring with a leading arc that turns once per `period`. The ring is static; the arc is a
/// `CAShapeLayer` sublayer anchored at its centre, which turns through a Core Animation rotation.
/// At rest (Reduce Motion) the arc starts at 3 o'clock.
public final class HfLayerSpinnerView: HfLayerAnimatedView {
    /// The key of the arc's rotation animation.
    public static let animationKey = "hfRunningSpinnerTurn"

    private let ringLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()

    var spec: HfLayerSpinnerSpec {
        didSet {
            guard spec != oldValue else { return }
            invalidateIntrinsicContentSize()
            configureLayers()
            needsLayout = true
            reinstallMotion()
        }
    }

    init(spec: HfLayerSpinnerSpec) {
        self.spec = spec
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: spec.diameter, height: spec.diameter)))
        for shape in [ringLayer, arcLayer] {
            shape.fillColor = nil
            layer?.addSublayer(shape)
        }
        ringLayer.lineCap = .butt
        arcLayer.lineCap = .round
        configureLayers()
    }

    /// The stroke width in points.
    public var lineWidth: CGFloat { spec.lineWidth }

    /// The circle's diameter in points.
    public var diameter: CGFloat { spec.diameter }

    override public var isFlipped: Bool { true }

    override public var intrinsicContentSize: NSSize { CGSize(width: spec.diameter, height: spec.diameter) }

    override public func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        HfLayerClock.withoutActions {
            for shape in [ringLayer, arcLayer] {
                shape.bounds = CGRect(origin: .zero, size: CGSize(width: spec.diameter, height: spec.diameter))
                shape.position = center
                shape.contentsScale = window?.backingScaleFactor ?? shape.contentsScale
            }
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        needsLayout = true
    }

    private func configureLayers() {
        let rect = CGRect(origin: .zero, size: CGSize(width: spec.diameter, height: spec.diameter))
        HfLayerClock.withoutActions {
            ringLayer.path = CGPath(ellipseIn: rect, transform: nil)
            ringLayer.lineWidth = spec.lineWidth
            // A clockwise circle from 3 o'clock, trimmed to the arc's share.
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                       startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            arcLayer.path = arc
            arcLayer.lineWidth = spec.lineWidth
            arcLayer.strokeStart = 0
            arcLayer.strokeEnd = spec.arcFraction
        }
        applyColors()
    }

    private func applyColors() {
        let spec = spec
        let resolved = NSColor(spec.color)
        HfLayerClock.withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ringLayer.strokeColor = resolved.withAlphaComponent(resolved.alphaComponent * spec.ringOpacity).cgColor
                arcLayer.strokeColor = resolved.cgColor
            }
        }
    }

    override func installMotion() {
        arcLayer.removeAnimation(forKey: Self.animationKey)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = spec.period
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.beginTime = HfLayerClock.beginTime(for: arcLayer, period: spec.period)
        arcLayer.add(animation, forKey: Self.animationKey)
    }

    override func removeMotion() {
        arcLayer.removeAnimation(forKey: Self.animationKey)
    }

    /// The turning arc layer, for inspection in tests.
    public var turningLayer: CALayer { arcLayer }

    /// The static ring layer, for inspection in tests.
    public var trackLayer: CALayer { ringLayer }
}

// MARK: - HfLayerSpinner

/// The representable under `RunningSpinner`. `animates` is false under Reduce Motion, which leaves
/// the static arc.
struct HfLayerSpinner: NSViewRepresentable {
    let spec: HfLayerSpinnerSpec
    let animates: Bool

    func makeNSView(context _: Context) -> HfLayerSpinnerView {
        let view = HfLayerSpinnerView(spec: spec)
        view.animates = animates
        return view
    }

    func updateNSView(_ view: HfLayerSpinnerView, context _: Context) {
        if view.spec != spec { view.spec = spec }
        if view.animates != animates { view.animates = animates }
    }

    func sizeThatFits(_: ProposedViewSize, nsView: HfLayerSpinnerView, context _: Context) -> CGSize? {
        CGSize(width: nsView.spec.diameter, height: nsView.spec.diameter)
    }
}
