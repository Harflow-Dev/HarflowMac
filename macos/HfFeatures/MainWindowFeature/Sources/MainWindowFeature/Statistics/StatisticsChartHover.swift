import CoreGraphics

// MARK: - StatisticsChartHover

/// Pure layout rules for the chart hover card: which day column the pointer is over and where the card sits.
/// All coordinates are in the plot's local space (origin at its top-leading corner) unless stated otherwise.
enum StatisticsChartHover {
    /// Distance between the card's bottom edge and the top of the hovered stacked bar.
    static let barClearance: CGFloat = 8
    /// Minimum distance between the card and the chart card's outer top edge.
    static let edgeMargin: CGFloat = 8

    /// The plot geometry the hover rules work on.
    struct Columns: Equatable {
        var plotSize: CGSize
        var count: Int
        var gap: CGFloat

        var columnWidth: CGFloat { (plotSize.width - CGFloat(max(count, 1) - 1) * gap) / CGFloat(max(count, 1)) }
    }

    /// The column under `x`; the gap between two columns belongs to the nearer column. Out-of-range input clamps.
    static func columnIndex(x: CGFloat, columns: Columns) -> Int? {
        let count = columns.count
        guard count > 0, columns.plotSize.width > 0, x.isFinite else { return nil }
        let pitch = columns.columnWidth + columns.gap
        guard pitch > 0 else { return nil }
        let index = Int(((x + columns.gap / 2) / pitch).rounded(.down))
        return min(max(index, 0), count - 1)
    }

    /// The horizontal centre of column `index`.
    static func columnCenter(index: Int, columns: Columns) -> CGFloat {
        CGFloat(index) * (columns.columnWidth + columns.gap) + columns.columnWidth / 2
    }

    /// The card's top-leading origin: bottom `barClearance` above the stacked bar top, centred on the column, kept inside
    /// the plot horizontally and no higher than `edgeMargin` inside the chart card's outer top edge, which lies
    /// `topInset` above the plot's top.
    static func cardOrigin(
        columns: Columns,
        index: Int,
        stackedFraction: Double,
        cardSize: CGSize,
        topInset: CGFloat
    ) -> CGPoint {
        let fraction = CGFloat(min(1, max(0, stackedFraction)))
        let barTop = columns.plotSize.height * (1 - fraction)
        let centre = columnCenter(index: index, columns: columns)
        let x = min(max(centre - cardSize.width / 2, 0), max(0, columns.plotSize.width - cardSize.width))
        let y = max(barTop - barClearance - cardSize.height, edgeMargin - topInset)
        return CGPoint(x: x, y: y)
    }

    /// Moves `origin` so the card frame lies inside `visibleRect` (same coordinate space). When the visible rect is
    /// smaller than the card on an axis, the card's top-leading corner stays visible.
    static func clamped(origin: CGPoint, cardSize: CGSize, to visibleRect: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, size: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            high - low < size ? low : min(max(value, low), high - size)
        }
        return CGPoint(
            x: clamp(origin.x, size: cardSize.width, low: visibleRect.minX, high: visibleRect.maxX),
            y: clamp(origin.y, size: cardSize.height, low: visibleRect.minY, high: visibleRect.maxY)
        )
    }
}
