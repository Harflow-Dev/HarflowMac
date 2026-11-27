import AppKit
import HfUI
import SwiftUI

// MARK: - WorkflowNodeOutline

/// Selection and execution are independent presentation states; reservation is not execution.
struct WorkflowNodeOutline {
    let status: String
    let isSelected: Bool
    var isExecuting: Bool { status == "running" }
    var isEmphasized: Bool { isSelected || isExecuting || status == "reserved" }
}

// MARK: - WorkflowRunningOutline

/// The running node's turning ring, drawn in Core Animation: a conic gradient layer that rotates once
/// every three seconds behind a ring-shaped mask. A SwiftUI `TimelineView` here kept the node's graph
/// pending at 30 Hz and re-measured the window root on every tick.
struct WorkflowRunningOutline: View {
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride

    var body: some View {
        // The layer view is larger than the node by the ring's overhang, so every pixel of the ring is inside
        // the AppKit view's own bounds (SwiftUI's old stroke drew outside the node's frame; a platform view's
        // sublayers outside its bounds are not something to rely on).
        LayerOutline(isSelected: isSelected, animates: !HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion))
            .padding(-LayerOutlineView.overhang)
    }
}

// MARK: - LayerOutline

/// The representable under `WorkflowRunningOutline`. It takes the size its parent gives it.
struct LayerOutline: NSViewRepresentable {
    let isSelected: Bool
    let animates: Bool

    func makeNSView(context _: Context) -> LayerOutlineView {
        let view = LayerOutlineView(isSelected: isSelected)
        view.animates = animates
        return view
    }

    func updateNSView(_ view: LayerOutlineView, context _: Context) {
        view.isSelected = isSelected
        if view.animates != animates { view.animates = animates }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: LayerOutlineView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

// MARK: - LayerOutlineView

/// A rounded ring filled by a conic gradient that turns once per `period`. The view's bounds are the node's
/// frame grown by `overhang` on every side, so the whole ring lies inside them. The gradient layer is a
/// square covering the whole view however it is shaped, and a non-turning ring-shaped mask on the
/// container keeps only the ring. Selection widens the ring (4 pt, 2 pt outside the card); otherwise it
/// is a 2 pt border inside the card, as the SwiftUI outline drew them. Reduce Motion leaves the
/// gradient at its starting angle.
final class LayerOutlineView: LayerMotionView {
    static let animationKey = "layerOutlineTurn"
    /// One full turn, in seconds.
    static let period: TimeInterval = 3
    /// The unselected border's width.
    static let borderWidth: CGFloat = 2

    private let gradientLayer = CAGradientLayer()
    private let ringMask = CAShapeLayer()

    var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsLayout = true
        }
    }

    init(isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.locations = [0, 1.0 / 3, 2.0 / 3, 1].map { NSNumber(value: $0) }
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        layer?.addSublayer(gradientLayer)
        layer?.mask = ringMask
        applyColors()
    }

    override var isFlipped: Bool { true }

    /// How far the ring can reach beyond the node's frame: the selected ring's 2 pt outset plus half its
    /// 4 pt stroke, rounded up to the whole stroke width.
    static let overhang: CGFloat = HfRadius.Metrics.workflowNodeRingInset + HfRadius.Metrics.workflowNodeRingWidth

    override func layout() {
        super.layout()
        let inset = isSelected ? -HfRadius.Metrics.workflowNodeRingInset : Self.borderWidth / 2
        let lineWidth = isSelected ? HfRadius.Metrics.workflowNodeRingWidth : Self.borderWidth
        // The node's frame, then the ring's rectangle around it, in this view's coordinates.
        let node = bounds.insetBy(dx: Self.overhang, dy: Self.overhang)
        let ring = node.insetBy(dx: inset, dy: inset)
        // `strokeBorder` insets the rounded rectangle, which shrinks its radius by the same amount.
        let radius = isSelected ? HfRadius.card : max(0, HfRadius.card - Self.borderWidth / 2)
        let scale = window?.backingScaleFactor ?? ringMask.contentsScale
        LayerMotion.withoutActions {
            ringMask.frame = bounds
            ringMask.contentsScale = scale
            ringMask.path = CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ringMask.lineWidth = lineWidth
            // A square covering the view from any angle, centred, so the turning gradient never leaves a
            // corner of the ring bare.
            let side = hypot(bounds.width, bounds.height)
            gradientLayer.bounds = CGRect(origin: .zero, size: CGSize(width: side, height: side))
            gradientLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            gradientLayer.contentsScale = scale
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let accent = NSColor(Color.accentLink)
        LayerMotion.withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let faint = accent.withAlphaComponent(accent.alphaComponent * 0.15).cgColor
                gradientLayer.colors = [faint, faint, accent.cgColor, faint]
            }
        }
    }

    override func installMotion() {
        gradientLayer.removeAnimation(forKey: Self.animationKey)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = Self.period
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.beginTime = LayerMotion.beginTime(for: gradientLayer, period: Self.period)
        gradientLayer.add(animation, forKey: Self.animationKey)
    }

    override func removeMotion() {
        gradientLayer.removeAnimation(forKey: Self.animationKey)
    }

    /// The turning gradient layer, for inspection in tests.
    var turningLayer: CALayer { gradientLayer }

    /// The ring mask, for inspection in tests.
    var maskLayer: CAShapeLayer { ringMask }
}

#if DEBUG
#Preview {
    WorkflowRunningOutline(isSelected: true).frame(width: 200, height: 90).padding()
}
#endif
