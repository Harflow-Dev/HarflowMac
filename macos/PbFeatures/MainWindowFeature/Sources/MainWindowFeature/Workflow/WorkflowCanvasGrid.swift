import Foundation

// MARK: - WorkflowCanvasGrid

/// Viewport-only dots retain logical grid alignment while keeping density stable on screen.
enum WorkflowCanvasGrid {
    static func spacing(scale: CGFloat) -> CGFloat {
        let scale = max(0.01, scale)
        var spacing = WorkflowCanvasGeometry.gridSpacing
        while spacing * scale < 20 { spacing *= 2 }
        return spacing
    }

    static func firstLocalDot(in viewport: CGRect, spacing: CGFloat) -> CGPoint {
        CGPoint(x: ceil(viewport.minX / spacing) * spacing - viewport.minX,
                y: ceil(viewport.minY / spacing) * spacing - viewport.minY)
    }

    static func screenDots(viewport: CGRect, scale: CGFloat, content: CGSize) -> [CGPoint] {
        guard scale > 0, !viewport.isEmpty else { return [] }
        let logical = CGRect(x: viewport.minX / scale, y: viewport.minY / scale,
                             width: viewport.width / scale, height: viewport.height / scale)
            .intersection(CGRect(origin: .zero, size: content))
        guard !logical.isNull, !logical.isEmpty else { return [] }
        let spacing = spacing(scale: scale)
        let first = firstLocalDot(in: logical, spacing: spacing)
        var points: [CGPoint] = []
        for x in stride(from: logical.minX + first.x, through: logical.maxX, by: spacing) {
            for y in stride(from: logical.minY + first.y, through: logical.maxY, by: spacing) {
                points.append(CGPoint(x: x * scale - viewport.minX, y: y * scale - viewport.minY))
            }
        }
        return points
    }

    static func diameter(scale: CGFloat) -> CGFloat { 1.7 / max(0.01, scale) }
}
