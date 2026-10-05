import SwiftUI

// MARK: - WorkflowArrowHover

enum WorkflowArrowHover {
    struct Candidate {
        let id: String
        let path: Path
        let points: [CGPoint]
    }

    static func nearest(to point: CGPoint, candidates: [Candidate]) -> String? {
        candidates.filter { $0.path.strokedPath(StrokeStyle(lineWidth: 18)).contains(point) }
            .min { first, second in
                let firstDistance = distance(point, to: first.points)
                let secondDistance = distance(point, to: second.points)
                return firstDistance == secondDistance ? first.id < second.id : firstDistance < secondDistance
            }?.id
    }

    static func viewportPoint(logical: CGPoint, scale: CGFloat, visibleOrigin: CGPoint) -> CGPoint {
        CGPoint(x: logical.x * scale - visibleOrigin.x, y: logical.y * scale - visibleOrigin.y)
    }

    static func tooltipCenter(cursor: CGPoint, size: CGSize, viewport: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        let offset: CGFloat = 14
        let proposedX = cursor.x + offset + size.width <= viewport.width - margin ? cursor.x + offset : cursor.x - offset - size.width
        let proposedY = cursor.y + offset + size.height <= viewport.height - margin ? cursor.y + offset : cursor.y - offset - size.height
        let origin = CGPoint(x: min(max(margin, proposedX), max(margin, viewport.width - margin - size.width)),
                             y: min(max(margin, proposedY), max(margin, viewport.height - margin - size.height)))
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private static func distance(_ point: CGPoint, to points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst())
.map { start, finish in
            let offsetX = finish.x - start.x
            let offsetY = finish.y - start.y
            let squaredLength = offsetX * offsetX + offsetY * offsetY
            let fraction = squaredLength == 0 ? 0 : min(1, max(0, ((point.x - start.x) * offsetX + (point.y - start.y) * offsetY) / squaredLength))
            return hypot(point.x - start.x - fraction * offsetX, point.y - start.y - fraction * offsetY)
        }
.min() ?? .greatestFiniteMagnitude
    }
}

// MARK: - WorkflowArrowHoverState

struct WorkflowArrowHoverState {
    let edgeID: String
    let point: CGPoint
}

// MARK: - WorkflowTooltipSizePreference

struct WorkflowTooltipSizePreference: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
