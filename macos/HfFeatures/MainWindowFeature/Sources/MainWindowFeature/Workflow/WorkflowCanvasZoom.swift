import Foundation

// MARK: - WorkflowCanvasZoom

enum WorkflowCanvasZoom {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 2
    static let increment: CGFloat = 0.25

    static func adjusted(_ scale: CGFloat, steps: Int) -> CGFloat {
        min(maximum, max(minimum, scale + CGFloat(steps) * increment))
    }

    // The named gesture space and drop target are on the untransformed, scaled-size wrapper.
    // Pointer values are display points; persisted node positions and routing always use logical points.
    static func logical(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x / scale, y: point.y / scale)
    }

    static func logical(_ size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: size.width / scale, height: size.height / scale)
    }

    static func contentSize(extent: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(extent.width, viewport.width / scale), height: max(extent.height, viewport.height / scale))
    }
}
