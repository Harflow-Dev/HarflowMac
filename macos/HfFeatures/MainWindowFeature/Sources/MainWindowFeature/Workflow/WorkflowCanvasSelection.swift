import SwiftUI

// MARK: - WorkflowCanvasSelection

enum WorkflowCanvasSelection {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func moved(origins: [String: CGPoint], delta: CGSize) -> [String: CGPoint] {
        let snapped = CGPoint(x: (delta.width / 10).rounded() * 10, y: (delta.height / 10).rounded() * 10)
        let offsetX = max(-(origins.values.map(\.x).min() ?? 0), snapped.x)
        let offsetY = max(-(origins.values.map(\.y).min() ?? 0), snapped.y)
        return origins.mapValues { CGPoint(x: $0.x + offsetX, y: $0.y + offsetY) }
    }
}
