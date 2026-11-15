import SwiftUI

// MARK: - StatusGlyphShape

/// The status glyphs no SF Symbol draws, transcribed from HarflowDesign `fe6428c` `v2/styles/bundle.css`
/// (`.hd-i-workflow` line 413, `.hd-i-parallel` line 401, `.hd-i-hand` line 412). Each path is drawn in the design's
/// 24 x 24 view box and scaled into the shape's square rect; stroke it with `StatusGlyphView` (round caps and joins).
/// SVG arcs are written as explicit centre arcs, converted from the SVG endpoint form in `SVGArc`.
public struct StatusGlyphShape: Shape, Sendable {

    /// Which design glyph the shape draws.
    public enum Kind: Equatable, Sendable, CaseIterable {
        /// Two rounded squares joined by a bent connector (`hd-i-workflow`).
        case workflow
        /// One line splitting into three (`hd-i-parallel`).
        case parallel
        /// The raised hand (`hd-i-hand`).
        case hand
    }

    /// The glyph this shape draws.
    public let kind: Kind

    /// Creates the shape for `kind`.
    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Self.viewBox
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let unit = Self.unitPath(kind)
        return unit.applying(CGAffineTransform(scaleX: scale, y: scale)).applying(CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// The design's view box edge.
    nonisolated static let viewBox: CGFloat = 24

    /// The glyph in view box units.
    nonisolated static func unitPath(_ kind: Kind) -> Path {
        switch kind {
        case .workflow: workflow()
        case .parallel: parallel()
        case .hand: hand()
        }
    }

    // MARK: Paths

    /// `M3 12h4M7 12c3 0 4-6 7-6h6M7 12h13M7 12c3 0 4 6 7 6h6`
    private nonisolated static func parallel() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3, y: 12))
        path.addLine(to: CGPoint(x: 7, y: 12))
        path.move(to: CGPoint(x: 7, y: 12))
        path.addCurve(to: CGPoint(x: 14, y: 6), control1: CGPoint(x: 10, y: 12), control2: CGPoint(x: 11, y: 6))
        path.addLine(to: CGPoint(x: 20, y: 6))
        path.move(to: CGPoint(x: 7, y: 12))
        path.addLine(to: CGPoint(x: 20, y: 12))
        path.move(to: CGPoint(x: 7, y: 12))
        path.addCurve(to: CGPoint(x: 14, y: 18), control1: CGPoint(x: 10, y: 12), control2: CGPoint(x: 11, y: 18))
        path.addLine(to: CGPoint(x: 20, y: 18))
        return path
    }

    /// `rect 3 3 7 7 rx1.5`, `rect 14 14 7 7 rx1.5`, `M6.5 10v4a3 3 0 0 0 3 3H14`
    private nonisolated static func workflow() -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
        path.addRoundedRect(in: CGRect(x: 14, y: 14, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
        path.move(to: CGPoint(x: 6.5, y: 10))
        path.addLine(to: CGPoint(x: 6.5, y: 14))
        path.addSVGArc(from: CGPoint(x: 6.5, y: 14), to: CGPoint(x: 9.5, y: 17), radius: 3, largeArc: false, sweep: false)
        path.addLine(to: CGPoint(x: 14, y: 17))
        return path
    }

    /// Four sub-paths:
    /// `M18 11V6a2 2 0 0 0-4 0v5`, `M14 10V4a2 2 0 0 0-4 0v6`, `M10 10.5V6a2 2 0 0 0-4 0v8`,
    /// `M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15`
    private nonisolated static func hand() -> Path {
        var path = Path()
        // Ring finger.
        path.move(to: CGPoint(x: 18, y: 11))
        path.addLine(to: CGPoint(x: 18, y: 6))
        path.addSVGArc(from: CGPoint(x: 18, y: 6), to: CGPoint(x: 14, y: 6), radius: 2, largeArc: false, sweep: false)
        path.addLine(to: CGPoint(x: 14, y: 11))
        // Middle finger.
        path.move(to: CGPoint(x: 14, y: 10))
        path.addLine(to: CGPoint(x: 14, y: 4))
        path.addSVGArc(from: CGPoint(x: 14, y: 4), to: CGPoint(x: 10, y: 4), radius: 2, largeArc: false, sweep: false)
        path.addLine(to: CGPoint(x: 10, y: 10))
        // Index finger.
        path.move(to: CGPoint(x: 10, y: 10.5))
        path.addLine(to: CGPoint(x: 10, y: 6))
        path.addSVGArc(from: CGPoint(x: 10, y: 6), to: CGPoint(x: 6, y: 6), radius: 2, largeArc: false, sweep: false)
        path.addLine(to: CGPoint(x: 6, y: 14))
        // Thumb and palm.
        path.move(to: CGPoint(x: 18, y: 8))
        path.addSVGArc(from: CGPoint(x: 18, y: 8), to: CGPoint(x: 22, y: 8), radius: 2, largeArc: true, sweep: true)
        path.addLine(to: CGPoint(x: 22, y: 14))
        path.addSVGArc(from: CGPoint(x: 22, y: 14), to: CGPoint(x: 14, y: 22), radius: 8, largeArc: false, sweep: true)
        path.addLine(to: CGPoint(x: 12, y: 22))
        path.addCurve(to: CGPoint(x: 6.01, y: 19.66), control1: CGPoint(x: 9.2, y: 22), control2: CGPoint(x: 7.5, y: 21.14))
        path.addLine(to: CGPoint(x: 2.41, y: 16.06))
        path.addSVGArc(from: CGPoint(x: 2.41, y: 16.06), to: CGPoint(x: 5.24, y: 13.24), radius: 2, largeArc: false, sweep: true)
        path.addLine(to: CGPoint(x: 7, y: 15))
        return path
    }
}

// MARK: - SVGArc

/// An SVG elliptical arc with equal radii and no rotation (path command `A r r 0 large sweep x y`), converted from the
/// endpoint form to cubic segments of at most a quarter turn. `sweep` follows SVG: true turns toward increasing angle
/// in the y-down view box, which is clockwise on screen.
struct SVGArc {
    let start: CGPoint
    let end: CGPoint
    let radius: CGFloat
    let largeArc: Bool
    let sweep: Bool

    nonisolated func append(to path: inout Path) {
        let halfDX = (start.x - end.x) / 2
        let halfDY = (start.y - end.y) / 2
        var scaled = radius
        let lambda = (halfDX * halfDX + halfDY * halfDY) / (scaled * scaled)
        if lambda > 1 { scaled *= lambda.squareRoot() }
        let squared = scaled * scaled
        let numerator = squared * squared - squared * halfDY * halfDY - squared * halfDX * halfDX
        let denominator = squared * halfDY * halfDY + squared * halfDX * halfDX
        var coefficient = max(0, numerator / denominator).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let centerPX = coefficient * halfDY
        let centerPY = -coefficient * halfDX
        let center = CGPoint(x: centerPX + (start.x + end.x) / 2, y: centerPY + (start.y + end.y) / 2)
        let startAngle = atan2((halfDY - centerPY) / scaled, (halfDX - centerPX) / scaled)
        let endAngle = atan2((-halfDY - centerPY) / scaled, (-halfDX - centerPX) / scaled)
        var delta = endAngle - startAngle
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)
        var angle = startAngle
        for _ in 0 ..< segments {
            let next = angle + step
            let from = CGPoint(x: center.x + scaled * cos(angle), y: center.y + scaled * sin(angle))
            let to = CGPoint(x: center.x + scaled * cos(next), y: center.y + scaled * sin(next))
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x - handle * scaled * sin(angle), y: from.y + handle * scaled * cos(angle)),
                control2: CGPoint(x: to.x + handle * scaled * sin(next), y: to.y - handle * scaled * cos(next))
            )
            angle = next
        }
    }
}

extension Path {
    /// Appends an SVG arc (`A r r 0 large sweep x y`) from `start`, which must be the current point.
    nonisolated mutating func addSVGArc(from start: CGPoint, to end: CGPoint, radius: CGFloat, largeArc: Bool, sweep: Bool) {
        SVGArc(start: start, end: end, radius: radius, largeArc: largeArc, sweep: sweep).append(to: &self)
    }
}

// MARK: - StatusGlyphView

/// A design glyph drawn as a stroked path in its square `size` frame: the icon is 14/16 of the frame with a stroke of
/// 1.8/24 of the icon, round caps and joins, in the surrounding foreground style (so an `onAccent` selected row works).
public struct StatusGlyphView: View {
    /// The glyph drawn.
    public let kind: StatusGlyphShape.Kind
    /// The glyph frame's edge; the icon is 14/16 of it.
    public let size: CGFloat

    /// Creates a glyph view in a `size` frame.
    public init(_ kind: StatusGlyphShape.Kind, size: CGFloat = HfRadius.Metrics.statusIconSize) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        let icon = size * HfRadius.Metrics.statusGlyphIconRatio
        StatusGlyphShape(kind)
            .stroke(style: StrokeStyle(lineWidth: icon * HfRadius.Metrics.statusGlyphStrokeRatio, lineCap: .round, lineJoin: .round))
            .frame(width: icon, height: icon)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("StatusGlyphShape - light") { StatusGlyphShapePreview().preferredColorScheme(.light) }
#Preview("StatusGlyphShape - dark") { StatusGlyphShapePreview().preferredColorScheme(.dark) }

private struct StatusGlyphShapePreview: View {
    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing16) {
            ForEach(StatusGlyphShape.Kind.allCases, id: \.self) { kind in
                StatusGlyphView(kind, size: HfRadius.Metrics.statusIconSize).foregroundStyle(Color.warningFG)
                StatusGlyphView(kind, size: 64).foregroundStyle(Color.primaryText)
            }
        }
        .padding()
        .background(Color.windowBG)
    }
}
#endif
