//
//  LayerMotion.swift
//  MainWindowFeature
//
//  The activity feed's running indicators (the streaming caret, the tool spinner, the working glyph
//  and the live-step pulse) move in Core Animation. A SwiftUI `TimelineView` or `repeatForever`
//  inside a hosted feed cell keeps that cell's graph pending every frame, and each pending update
//  climbs to the feed's platform host, which then re-runs `fittingSize` over the whole table. A layer
//  animation runs in the render server: no SwiftUI view updates per frame and no nested hosting view.
//

import AppKit
import SwiftUI

// MARK: - LayerMotion

/// Shared timing for the feed's layer-driven indicators.
enum LayerMotion {
    /// The layer-time `beginTime` that makes an animation of the given `period` sit at the same phase
    /// as the reference-date clock (`phase = referenceDate mod period`). Re-derived on every add, so
    /// indicators mounted at different moments, and cells recycled into the feed, all agree.
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

// MARK: - LayerMotionView

/// A layer-backed view that owns one repeating animation. The animation is added or removed only on
/// a transition: the view entering or leaving a window, or `animates` flipping. Setting `animates` to
/// its current value, or moving between windows, does nothing. Removing the animation leaves the
/// static look (the Reduce Motion look).
class LayerMotionView: NSView {
    /// Whether the indicator should move. Reduce Motion drives this to `false`.
    final var animates = false {
        didSet { if animates != oldValue { syncMotion() } }
    }

    /// Whether the animation is currently on the layer.
    private(set) final var isMotionInstalled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The owning SwiftUI wrapper decides what, if anything, the indicator exposes.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncMotion()
    }

    private func syncMotion() {
        let shouldRun = animates && window != nil
        guard shouldRun != isMotionInstalled else { return }
        isMotionInstalled = shouldRun
        if shouldRun { installMotion() } else { removeMotion() }
    }

    /// Adds the animation. Called only on the transition to running, with the view in a window.
    func installMotion() {}

    /// Removes the animation and restores the static look.
    func removeMotion() {}
}

// MARK: - LayerCaretView

/// The streaming caret: `▍` drawn from an attributed string, sized and placed like `Text("▍")` in
/// `NSFont.monospacedSystemFont(ofSize: HfTextStyle.body.pointSize)`. Its blink is an opacity
/// keyframe animation on the backing layer.
final class LayerCaretView: LayerMotionView {
    static let animationKey = "layerCaretBlink"
    static let glyph = "▍"
    static let keyframeSteps = 24

    private let color: Color
    private let attributed: NSAttributedString
    private let textSize: CGSize
    let glyphSize: CGSize

    init(font: NSFont, color: Color) {
        self.color = color
        self.attributed = NSAttributedString(string: Self.glyph, attributes: [.font: font])
        self.textSize = attributed.size()
        // `Text` reports a whole-point width and height.
        self.glyphSize = CGSize(width: ceil(textSize.width), height: ceil(textSize.height))
        super.init(frame: CGRect(origin: .zero, size: glyphSize))
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { glyphSize }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        // `Text` centres the run in its whole-point frame, snapped to the pixel grid.
        let scale = window?.backingScaleFactor ?? 2
        let offsetX = ((glyphSize.width - textSize.width) / 2 * scale).rounded() / scale
        let offsetY = ((glyphSize.height - textSize.height) / 2 * scale).rounded() / scale
        // Resolved under this view's effective appearance, so a live appearance switch repaints.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let drawn = NSMutableAttributedString(attributedString: attributed)
            drawn.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: 0, length: drawn.length))
            drawn.draw(at: CGPoint(x: offsetX, y: offsetY))
        }
    }

    override func installMotion() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        let steps = Self.keyframeSteps
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = (0 ... steps).map { StreamingCaret.opacity(atPhase: StreamingCaret.period * Double($0) / Double(steps)) }
        animation.duration = StreamingCaret.period
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        animation.beginTime = LayerMotion.beginTime(for: layer, period: StreamingCaret.period)
        layer.add(animation, forKey: Self.animationKey)
    }

    override func removeMotion() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        LayerMotion.withoutActions { layer.opacity = 1 }
    }
}

// MARK: - LayerSpinnerSpec

/// The look of a turning ring-and-arc indicator. Colours are SwiftUI values so equal specs compare
/// equal and an unchanged spec never touches the layers.
struct LayerSpinnerSpec: Equatable {
    /// The circle's diameter; the stroke is centred on its edge, as `Circle().stroke` is.
    var diameter: CGFloat
    /// Space around the circle inside the view's frame.
    var margin: CGFloat = 0
    var lineWidth: CGFloat
    /// The leading arc's share of the circle, drawn clockwise from 3 o'clock.
    var arcFraction: CGFloat
    /// One full turn.
    var period: TimeInterval
    var ringColor: Color
    var ringOpacity: Double = 1
    var arcColor: Color

    /// The view's side length.
    var side: CGFloat { diameter + 2 * margin }
}

// MARK: - LayerSpinnerView

/// A ring with a leading arc that turns once per `spec.period`. The ring is static; the arc is a
/// `CAShapeLayer` sublayer the view owns, anchored at its centre and re-centred in `layout()`, which
/// turns through a Core Animation rotation. At rest the arc starts at 3 o'clock.
final class LayerSpinnerView: LayerMotionView {
    static let animationKey = "layerSpinnerTurn"

    private let ringLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()

    var spec: LayerSpinnerSpec {
        didSet {
            guard spec != oldValue else { return }
            let wasInstalled = isMotionInstalled
            if wasInstalled { removeMotion() }
            invalidateIntrinsicContentSize()
            configureLayers()
            needsLayout = true
            if wasInstalled { installMotion() }
        }
    }

    init(spec: LayerSpinnerSpec) {
        self.spec = spec
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: spec.side, height: spec.side)))
        for shape in [ringLayer, arcLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        ringLayer.lineCap = .butt
        configureLayers()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { CGSize(width: spec.side, height: spec.side) }

    override func layout() {
        super.layout()
        let side = spec.diameter
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        LayerMotion.withoutActions {
            for shape in [ringLayer, arcLayer] {
                shape.bounds = CGRect(origin: .zero, size: CGSize(width: side, height: side))
                shape.position = center
                shape.contentsScale = window?.backingScaleFactor ?? shape.contentsScale
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        needsLayout = true
    }

    private func configureLayers() {
        let rect = CGRect(origin: .zero, size: CGSize(width: spec.diameter, height: spec.diameter))
        LayerMotion.withoutActions {
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
        let ring = NSColor(spec.ringColor)
        let arc = NSColor(spec.arcColor)
        LayerMotion.withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ringLayer.strokeColor = ring.withAlphaComponent(ring.alphaComponent * spec.ringOpacity).cgColor
                arcLayer.strokeColor = arc.cgColor
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
        animation.beginTime = LayerMotion.beginTime(for: arcLayer, period: spec.period)
        arcLayer.add(animation, forKey: Self.animationKey)
    }

    override func removeMotion() {
        arcLayer.removeAnimation(forKey: Self.animationKey)
    }

    /// The arc layer, for inspection in tests.
    var turningLayer: CALayer { arcLayer }

    /// The static ring layer, for inspection in tests.
    var trackLayer: CALayer { ringLayer }
}

// MARK: - LayerPulseDotView

/// A filled dot whose opacity eases between 1 and `dimmedOpacity` and back, in Core Animation.
final class LayerPulseDotView: LayerMotionView {
    static let animationKey = "layerDotPulse"
    /// One way, dim or bright; the full cycle is twice this.
    static let halfPeriod: TimeInterval = 0.8
    static let dimmedOpacity: Float = 0.3

    var diameter: CGFloat {
        didSet {
            guard diameter != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var color: Color {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    init(diameter: CGFloat, color: Color) {
        self.diameter = diameter
        self.color = color
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)))
    }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize { CGSize(width: diameter, height: diameter) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        let resolved = NSColor(color)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = resolved.cgColor
        }
        layer.cornerRadius = diameter / 2
    }

    override func installMotion() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = Self.dimmedOpacity
        animation.duration = Self.halfPeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        animation.beginTime = LayerMotion.beginTime(for: layer, period: 2 * Self.halfPeriod)
        layer.add(animation, forKey: Self.animationKey)
    }

    override func removeMotion() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        LayerMotion.withoutActions { layer.opacity = 1 }
    }
}
